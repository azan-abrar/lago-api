# frozen_string_literal: true

module PaymentRequests
  module Payments
    class MoneyhashService < BaseService
      include Customers::PaymentProviderFinder

      PENDING_STATUSES = %w[UNPROCESSED]
        .freeze
      SUCCESS_STATUSES = %w[PROCESSED].freeze
      FAILED_STATUSES = %w[FAILED].freeze

      def initialize(payable = nil)
        @payable = payable

        super(nil)
      end

      def create
        result.payable = payable
        return result unless should_process_payment?

        unless payable.total_amount_cents.positive?
          update_payable_payment_status(payment_status: :succeeded)
          return result
        end

        payable.increment_payment_attempts!

        moneyhash_result = create_moneyhash_payment_url
        moneyhash_result_data = moneyhash_result["data"]

        return result unless moneyhash_result

        payment = Payment.new(
          payable: payable,
          payment_provider_id: moneyhash_payment_provider.id,
          payment_provider_customer_id: customer.moneyhash_customer.id,
          amount_cents: payable.amount_cents,
          amount_currency: payable.currency&.upcase,
          provider_payment_id: moneyhash_result_data["id"],
          status: moneyhash_result_data["status"]
        )

        payment.save!

        payable_payment_status = payable_payment_status(payment.status)
        payment_url_exist = moneyhash_result_data["embed_url"]

        update_payable_payment_status(payment_status: payable_payment_status)
        update_invoices_payment_status(payment_status: payable_payment_status)

        Integrations::Aggregator::Payments::CreateJob.perform_later(payment:) if payment.should_sync_payment?

        if payment_url_exist
          SendWebhookJob.perform_later(
            'customer.checkout_url_generated',
            customer,
            checkout_url: result.checkout_url
          )
        end

        result.payment = payment
        result
      end

      private

      attr_accessor :payable

      delegate :organization, :customer, to: :payable

      def moneyhash_payment_method
        customer.moneyhash_customer.payment_method_id
      end

      def should_process_payment?
        return false if payable.payment_succeeded?
        return false if moneyhash_payment_provider.blank?

        !!customer&.moneyhash_customer&.provider_customer_id
      end

      def client
        @client || LagoHttpClient::Client.new("#{::PaymentProviders::MoneyhashProvider.api_base_url}/api/v1.1/payments/intent/")
      end

      def headers
        {
          'Content-Type' => 'application/json',
          'x-Api-Key' => moneyhash_payment_provider.api_key
        }
      end

      def moneyhash_payment_provider
        @moneyhash_payment_provider ||= payment_provider(customer)
      end

      def create_moneyhash_payment_url
        payment_params = {
          amount: payable.total_amount_cents,
          amount_currency: payable.currency.upcase,
          expires_after_seconds: 600,
          operation: "purchase",
          billing_data: {
            first_name: customer.firstname,
            last_name: customer.lastname,
            phone_number: customer.phone,
            email: customer.email,
            city: customer.city,
            country: payable.country.upcase,
            state: customer.state
          },
          customer: customer.external_id,
          successful_redirect_url: moneyhash_payment_provider.success_redirect_url,
          failed_redirect_url: moneyhash_payment_provider.failed_redirect_url,
          pending_external_action_redirect_url: moneyhash_payment_provider.pending_external_action_redirect_url,
          webhook_url: moneyhash_payment_provider.webhook_url,
          merchant_initiated: false,
          tokenize_card: true,
          payment_type: "UNSCHEDULED",
          recurring_data: {
            agreement_id: payable.id
          }
        }

        response = client.post_with_response(payment_params, headers)
        JSON.parse(response.body)
      rescue LagoHttpClient::HttpError => e
        deliver_error_webhook(e)
        update_payable_payment_status(payment_status: :failed, deliver_webhook: false)
        nil
      end

      def payable_payment_status(payment_status)
        return :pending if PENDING_STATUSES.include?(payment_status)
        return :succeeded if SUCCESS_STATUSES.include?(payment_status)
        return :failed if FAILED_STATUSES.include?(payment_status)

        payment_status
      end

      def update_payable_payment_status(payment_status:, deliver_webhook: true)
        UpdateService.call(
          payable: result.payable,
          params: {
            payment_status:,
            ready_for_payment_processing: payment_status.to_sym != :succeeded
          },
          webhook_notification: deliver_webhook
        ).raise_if_error!
      end

      def update_invoices_payment_status(payment_status:, deliver_webhook: true)
        result.payable.invoices.each do |invoice|
          Invoices::UpdateService.call(
            invoice:,
            params: {
              payment_status:,
              ready_for_payment_processing: payment_status.to_sym != :succeeded
            },
            webhook_notification: deliver_webhook
          ).raise_if_error!
        end
      end

      def deliver_error_webhook(moneyhash_error)
        DeliverErrorWebhookService.call_async(payable, {
          provider_customer_id: customer.moneyhash_customer.provider_customer_id,
          provider_error: {
            message: moneyhash_error.message,
            error_code: moneyhash_error.error_code
          }
        })
      end
    end
  end
end
