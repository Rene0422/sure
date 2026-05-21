require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterErrorHandlingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "AT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  test "handle_sync_error handles unauthorized EnableBankingError" do
    error = Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error handles not_found EnableBankingError" do
    error = Provider::EnableBanking::EnableBankingError.new("Not Found", :not_found)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error handles other EnableBankingError as api_error" do
    error = Provider::EnableBanking::EnableBankingError.new("Some API error", :internal_server_error)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.api_error"), message
    assert_not @enable_banking_item.reload.requires_update?
  end

  test "fetch_session_data updates status to requires_update on unauthorized error" do
    def @mock_provider.get_session(**args)
      raise Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    end

    @importer.send(:fetch_session_data)

    assert @enable_banking_item.reload.requires_update?
  end

  test "fetch_and_store_transactions updates status to requires_update on unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.expects(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized))

    @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert @enable_banking_item.reload.requires_update?
  end

  test "fetch_and_store_transactions succeeds and skips pending when ASPSP rejects PDNG transaction_status" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    pdng_error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: {\"message\":\"Wrong transactionStatus provided in getAccountTransactions call: PDNG\"}",
      :validation_error
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(pdng_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert result[:success]
  end

  # Regression for #1805: ImaginV2 (and other Enable Banking connectors) reject PDNG with
  # a generic WRONG_REQUEST_PARAMETERS body whose message does not mention "transactionStatus".
  # The sync must still succeed and import booked transactions.
  test "fetch_and_store_transactions succeeds when ASPSP rejects PDNG with WRONG_REQUEST_PARAMETERS" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    imagin_error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: {\"error\":\"WRONG_REQUEST_PARAMETERS\"}",
      :validation_error,
      response_data: { error: "WRONG_REQUEST_PARAMETERS" }
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(imagin_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert result[:success]
  end

  test "fetch_and_store_transactions propagates non-validation EnableBankingError from PDNG fetch" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    rate_limit_error = Provider::EnableBanking::EnableBankingError.new(
      "Rate limit exceeded. Please try again later.",
      :rate_limited
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(rate_limit_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert_not result[:success]
  end

  test "fetch_and_update_balance updates status to requires_update on unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    def @mock_provider.get_account_balances(**args)
      raise Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    end

    @importer.send(:fetch_and_update_balance, enable_banking_account)

    assert @enable_banking_item.reload.requires_update?
  end
end
