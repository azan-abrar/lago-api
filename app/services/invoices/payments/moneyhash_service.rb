# frozen_string_literal: true

module Invoices
  module Payments
    class MoneyhashService < BaseService
      include Customers::PaymentProviderFinder

      def initialize(invoice = nil)
        @invoice = invoice

        super(nil)
      end

      def generate_payment_url
        return result unless should_process_payment?

        response = client.post_with_response(payment_url_params, headers)
        moneyhash_result = JSON.parse(response.body)

        return result unless moneyhash_result

        moneyhash_result_data = moneyhash_result["data"]
        result.payment_url = moneyhash_result_data["embed_url"]
        result
      rescue LagoHttpClient::HttpError => e
        deliver_error_webhook(e)
        result.service_failure!(code: e.error_code, message: e.message)
      end

      private

      attr_accessor :invoice

      delegate :organization, :customer, to: :invoice

      def should_process_payment?
        return false if invoice.payment_succeeded? || invoice.voided?
        return false if moneyhash_payment_provider.blank?

        customer&.moneyhash_customer&.provider_customer_id
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

      def payment_url_params
        {
          amount: invoice.total_amount_cents,
          amount_currency: invoice.currency.upcase,
          expires_after_seconds: 600,
          operation: "purchase",
          billing_data: {
            first_name: invoice&.customer&.firstname,
            last_name: invoice&.customer&.lastname,
            phone_number: invoice&.customer&.phone,
            email: invoice&.customer&.email
          },
          customer: invoice.customer.moneyhash_customer.provider_customer_id,
          successful_redirect_url: moneyhash_payment_provider.success_redirect_url,
          failed_redirect_url: moneyhash_payment_provider.failed_redirect_url,
          pending_external_action_redirect_url: moneyhash_payment_provider.pending_external_action_redirect_url,
          webhook_url: moneyhash_payment_provider.webhook_url,
          merchant_initiated: false,
          tokenize_card: true,
          payment_type: "UNSCHEDULED",
          recurring_data: {
            agreement_id: invoice.id
          }
        }
      end

      def deliver_error_webhook(moneyhash_error)
        DeliverErrorWebhookService.call_async(invoice, {
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
