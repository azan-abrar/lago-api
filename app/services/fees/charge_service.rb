# frozen_string_literal: true

module Fees
  class ChargeService < BaseService
    def initialize(invoice:, charge:)
      @invoice = invoice
      @charge = charge
      super(nil)
    end

    def create
      return result if already_billed?

      amount_result = compute_amount
      return result.fail!(amount_result.error_code, amount_result.error) unless amount_result.success?

      new_fee = Fee.new(
        invoice: invoice,
        subscription: subscription,
        charge: charge,
        amount_cents: amount_result.amount_cents,
        amount_currency: charge.amount_currency,
        vat_rate: customer.applicable_vat_rate,
        units: amount_result.units,
      )

      new_fee.compute_vat
      new_fee.save!

      result.fee = new_fee
      result
    rescue ActiveRecord::RecordInvalid => e
      result.fail_with_validations!(e.record)
    end

    private

    attr_accessor :invoice, :charge

    delegate :customer, :plan, :subscription, to: :invoice
    delegate :billable_metric, to: :charge

    def compute_amount
      aggregated_events = aggregator.aggregate(from_date: from_date, to_date: invoice.to_date)
      return aggregated_events unless aggregated_events.success?

      charge_model.apply(value: aggregated_events.aggregation)
    end

    def already_billed?
      existing_fee = invoice.fees.find_by(charge_id: charge.id)
      return false unless existing_fee

      result.fee = existing_fee
      true
    end

    def aggregator
      return @aggregator if @aggregator

      aggregator_service = case billable_metric.aggregation_type.to_sym
                           when :count_agg
                             BillableMetrics::Aggregations::CountService
                           when :max_agg
                             BillableMetrics::Aggregations::MaxService
                           when :sum_agg
                             BillableMetrics::Aggregations::SumService
                           when :unique_count_agg
                             BillableMetrics::Aggregations::UniqueCountService
                           else
                             raise NotImplementedError
      end

      @aggregator = aggregator_service.new(billable_metric: billable_metric, subscription: subscription)
    end

    def charge_model
      return @charge_model if @charge_model

      model_service = case charge.charge_model.to_sym
                      when :standard
                        Charges::ChargeModels::StandardService
                      when :graduated
                        Charges::ChargeModels::GraduatedService
                      when :package
                        Charges::ChargeModels::PackageService
                      else
                        raise NotImplementedError
      end

      @charge_model = model_service.new(charge: charge)
    end

    def from_date
      return invoice.from_date unless subscription.previous_subscription

      if subscription.previous_subscription.upgraded?
        date = case plan.interval.to_sym
               when :monthly
                 invoice.from_date.beginning_of_month
               when :yearly
                 invoice.from_date.beginning_of_year
               else
                 raise NotImplementedError
        end

        return date
      end

      invoice.from_date
    end
  end
end
