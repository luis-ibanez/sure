require "test_helper"

# The app can run before the finish_reason migration: the column really is missing here. No
# wrapping transaction, as on the web thread (smart fill and smart configure open none), so the
# failed write doesn't abort the statements after it.
class Ai::Instrumentation::UsageBeforeFinishReasonMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  URL = "https://llm.example.test/v1/chat/completions".freeze
  ANSWER = { name: "Netflix", amount: 15.49, frequency: "monthly", day_of_month: 3, weekday: nil, month_of_year: nil,
             category_name: nil, bill_type: "subscription", autopay: nil, confidence: 0.9, rationale: "two charges" }.freeze

  setup do
    @family = families(:dylan_family)
    @log = StringIO.new
    @logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
    ActiveRecord::Base.connection.remove_column :llm_usages, :finish_reason
    LlmUsage.reset_column_information
  end

  teardown do
    Rails.logger = @logger
    ActiveRecord::Base.connection.add_column :llm_usages, :finish_reason, :string unless ActiveRecord::Base.connection.column_exists?(:llm_usages, :finish_reason)
    LlmUsage.reset_column_information
    @family.llm_usages.delete_all
  end

  test "bill setup answers and its usage row is written; the finish reason is logged as not written" do
    stub_request(:post, URL).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "c1", model: "m", choices: [ { index: 0, message: { role: "assistant", content: ANSWER.to_json }, finish_reason: "stop" } ],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }.to_json)

    result = Ai::Generations::SuggestBillSetup.new(charges: [ { date: "2026-09-03", amount: "15.49", name: "NETFLIX.COM" } ], categories: [],
                                                   family: @family).call(plan:, down_marks: false)

    assert result.success?
    assert_equal "Netflix", result.value[:name]
    assert_equal [ "succeeded" ], @family.llm_usages.where(operation: "bill_setup").pluck(:status)
    assert_match(/UsageSubscriber\] ActiveRecord::StatementInvalid: PG::UndefinedColumn/, @log.string)
  end

  test "a failed call keeps its error even when its finish reason can't be written" do
    call_id = SecureRandom.uuid
    row = @family.llm_usages.create!(provider: "openai", model: "m", operation: "bill_setup", status: "failed", call_id:,
                                     prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, estimated_cost: 0)
    payload = { call_id:, family_id: @family.id, error: "Ai::Error::Timeout", error_message: "timed out", finish_reason: "length" }

    Ai::Instrumentation::UsageSubscriber.new.call(ActiveSupport::Notifications::Event.new("generate.ai", nil, nil, "e1", payload))

    assert_equal "timed out", row.reload.metadata["error"]
    assert_match(/PG::UndefinedColumn/, @log.string)
  end

  private
    def plan
      endpoint = Ai::Config::Endpoint.new(name: "openai_compatible", protocol: :compatible, base_url: "https://llm.example.test/v1", api_key: "k")
      model = Ai::Config::Model.new(endpoint:, name: "m", capabilities: %i[structured_output])
      Ai::Plan.new(feature: :bill_setup, lane: :interactive, routes: [ Ai::Route.new(feature: :bill_setup, model:, prompt: "bill_setup") ])
    end
end
