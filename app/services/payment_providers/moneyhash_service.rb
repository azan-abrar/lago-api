# frozen_string_literal: true

module PaymentProviders
  class MoneyhashService < BaseService

    INTENT_WEBHOOKS_EVENTS = %w[intent.processed intent.time_expired].freeze
    TRANSACTION_WEBHOOKS_EVENTS = %w[transaction.purchase.failed transaction.purchase.pending transaction.purchase.successful].freeze
    CARD_WEBHOOKS_EVENTS = %w[card_token.created card_token.updated card_token.deleted].freeze

    ALLOWED_WEBHOOK_EVENTS = (INTENT_WEBHOOKS_EVENTS + TRANSACTION_WEBHOOKS_EVENTS + CARD_WEBHOOKS_EVENTS).freeze

    PAYMENT_SERVICE_CLASS_MAP = {
      "Invoice" => Invoices::Payments::MoneyhashService,
      "PaymentRequest" => PaymentRequests::Payments::MoneyhashService
    }.freeze

    def create_or_update(**args)
      payment_provider_result = PaymentProviders::FindService.call(
        organization_id: args[:organization].id,
        code: args[:code],
        id: args[:id],
        payment_provider_type: 'moneyhash'
      )

      moneyhash_provider = if payment_provider_result.success?
        payment_provider_result.payment_provider
      else
        PaymentProviders::MoneyhashProvider.new(
          organization_id: args[:organization].id,
          code: args[:code]
        )
      end

      api_key = adyen_provider.api_key
      old_code = moneyhash_provider.code
      moneyhash_provider.api_key = args[:api_key] if args.key?(:api_key)
      moneyhash_provider.code = args[:code] if args.key?(:code)
      moneyhash_provider.name = args[:name] if args.key?(:name)
      moneyhash_provider.webhook_redirect_url = args[:webhook_redirect_url] if args.key?(:webhook_redirect_url)
      moneyhash_provider.failed_redirect_url = args[:failed_redirect_url] if args.key?(:failed_redirect_url)
      moneyhash_provider.pending_redirect_url = args[:pending_redirect_url] if args.key?(:pending_redirect_url)
      moneyhash_provider.success_redirect_url = args[:success_redirect_url] if args.key?(:success_redirect_url)

      moneyhash_provider.save(validate: false)

      if payment_provider_code_changed?(moneyhash_provider, old_code, args)
        moneyhash_provider.customers.update_all(payment_provider_code: args[:code]) # rubocop:disable Rails/SkipsModelValidations
      end

      result.moneyhash_provider = moneyhash_provider
      result
    rescue ActiveRecord::RecordInvalid => e
      result.record_validation_failure!(record: e.record)
    end

    def handle_event(organization:, event_json:)
      @event_json = event_json
      @event_code = event_json['type']
      @organization = organization

      unless ALLOWED_WEBHOOK_EVENTS.include?(@event_code)
        return result.service_failure!(
          code: 'webhook_error',
          message: "Invalid moneyhash event code: #{@event_code}"
        )
      end
      event_handlers.fetch(@event_code, method(:default_handler)).call
    end

    private

    def event_handlers
      {
        'intent.time_expired' => method(:handle_intent_event),
        'transaction.purchase.failed' => method(:handle_transaction_event),
        'transaction.purchase.pending' => method(:handle_transaction_event),
        'transaction.purchase.successful' => method(:handle_transaction_event),
        'card_token.created' => method(:handle_card_event),
        'card_token.updated' => method(:handle_card_event),
        'card_token.deleted' => method(:handle_card_event)
      }
    end

    def handle_intent_event
      payment_statuses = {
        'intent.time_expired': 'failed'
      }
      case @event_code
      when 'intent.time_expired'
        payment_service_klass(@event_json)
          .new.update_payment_status(
            organization_id: @organization.id,
            provider_payment_id: @event_json.dig('data','intent_id'),
            status: payment_statuses[@event_code.to_sym],
            metadata: @event_json.dig('data', 'intent', 'custom_fields')
          ).raise_if_error!
      end
    end

    def handle_transaction_event
      payment_statuses = {
        'transaction.purchase.failed': 'failed',
        'transaction.purchase.pending': 'processing',
        'transaction.purchase.successful': 'succeeded'
      }
      case @event_code
      when 'transaction.purchase.failed', 'transaction.purchase.pending', 'transaction.purchase.successful'
        payment_service_klass(@event_json)
          .new.update_payment_status(
            organization_id: @organization.id,
            provider_payment_id: @event_json.dig('intent', 'id'),
            status: payment_statuses[@event_code.to_sym],
            metadata: @event_json.dig('intent','custom_fields')
          ).raise_if_error!
      end
    end

    def handle_card_event
      service = PaymentProviderCustomers::MoneyhashService.new

      case @event_code
      when 'card_token.deleted'
        payment_method_id = @event_json.dig('data','card_token', 'id')
        customer_id = @event_json.dig('data','card_token', 'custom_fields', 'lago_customer_id')
        customer = PaymentProviderCustomers::MoneyhashCustomer.find_by(customer_id: customer_id)

        selected_payment_method_id = (customer&.payment_method_id == payment_method_id) ? nil : payment_method_id
        service
          .update_payment_method(
            organization_id: @organization.id,
            customer_id: customer_id,
            payment_method_id: selected_payment_method_id,
            metadata: @event_json.dig('data','card_token', 'custom_fields')
          ).raise_if_error!

      when 'card_token.created','card_token.updated'
        service
          .update_payment_method(
            organization_id: @organization.id,
            customer_id: @event_json.dig('data','card_token', 'custom_fields', 'lago_customer_id'),
            payment_method_id: @event_json.dig('data','card_token', 'id'),
            metadata: @event_json.dig('data','card_token', 'custom_fields')
          ).raise_if_error!
      end
    end

    def payment_service_klass(event_json)
      payable_type = event_json.dig('intent', 'custom_fields', 'lago_payable_type') || "Invoice"
      PAYMENT_SERVICE_CLASS_MAP.fetch(payable_type) do
        raise NameError, "Invalid lago_payable_type: #{payable_type}"
      end
    end

    def default_handler
      result.service_failure!(
        code: 'webhook_error',
        message: "No handler for event code: #{@event_code}"
      )
    end
  end
end
