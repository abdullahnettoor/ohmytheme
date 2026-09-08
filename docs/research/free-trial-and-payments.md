# Free trial now, payments later

Research date: 2026-09-04

## Scope and evidence standard

This note recommends a trial and payment design for Oh My Theme, using Dockspace as a public product reference. It uses only first-party sources: this repository, Dockspace's own site and legal pages, Apple documentation, and billing-provider documentation.

Labels used below:

- **Verified** means a first-party source states or implements the claim.
- **Inference** means the available facts support the conclusion, but the source does not state it.
- **Recommendation** is proposed behavior for Oh My Theme.
- **Unknown** marks a point that the public sources do not settle.

## Decision

Implement a provider-neutral, full-featured 14-day trial now. Start the trial when the first theme apply succeeds, not when the app is downloaded or first opened. Keep the current beta free until the trial UX and expiration behavior have been tested.

When payments are enabled, keep the existing direct-download distribution and sell a one-time personal license through Polar, subject to successful India onboarding/payout activation and review of the accounting and tax treatment by a qualified Indian CA or lawyer. Open Polar's hosted checkout in the default browser, use Polar's license-key benefit with a three-device activation limit, and store the entered key and activation ID in Keychain. Do not put a Polar organization access token in the app. Polar documents customer-facing activation and validation requests that take the license key and organization ID, while its organization API endpoints require bearer credentials. [Polar license-key benefit](https://polar.sh/docs/features/benefits/license-keys.md) [Polar authenticated validation endpoint](https://polar.sh/docs/api-reference/2026-04/license_keys/validate-license-key.md)

Do not pursue a Mac App Store build for this payment release. The repository has already chosen direct, non-sandboxed distribution because its core work needs broad user-approved configuration access, command execution, and symlink handling. The Mac App Store would also prohibit a launch-time license screen, license keys, and custom copy protection, and would require In-App Purchase for an in-app full unlock. [Repository distribution ADR](../adr/0007-direct-non-sandboxed-distribution.md) [Apple App Review Guidelines 2.4.5 and 3.1.1](https://developer.apple.com/app-store/review/guidelines/)

## What the products currently are

### Oh My Theme

**Verified.** Oh My Theme is a native macOS 14-or-later menu-bar utility that applies one theme assignment across a connected developer workspace. Its SwiftUI app uses `MenuBarExtra`; the beta is directly distributed outside the Mac App Store with App Sandbox disabled. [README](../../README.md) [MVP plan](../architecture/mvp-plan.md#product-contract) [Technical stack](../architecture/technical-stack.md#platform) [App build configuration](../../Config/App.xcconfig)

**Verified.** The current beta explicitly excludes pricing, payments, and Free or Pro tiers. Its architecture places mutations behind `ThemeEngine`, uses GRDB for durable application state, and reserves Keychain for secrets. [MVP exclusions](../architecture/mvp-plan.md#excluded-from-the-beta) [Technical stack, runtime](../architecture/technical-stack.md#runtime-and-concurrency) [Technical stack, persistence](../architecture/technical-stack.md#persistence)

**Inference.** Access control should become a policy in front of mutating engine operations rather than checks scattered through SwiftUI. This follows the existing rule that presentation code does not own theme application, persistence, or other side effects. [Technical stack](../architecture/technical-stack.md#runtime-and-concurrency)

### Dockspace

**Verified public product facts.** Dockspace presents itself as a native Swift macOS dock replacement for macOS 14 or later. It distributes a DMG and advertises Homebrew installation. The site says the app requires no account and offers a full-access trial without a credit card. The paid offer is a one-time $9.99 license with future updates, plus discounted two-, three-, and five-Mac options. Its pricing page names Polar Payments. [Dockspace home](https://getdockspace.app/) [Dockspace pricing](https://getdockspace.app/pricing) [Homebrew cask](https://formulae.brew.sh/cask/dockspace)

**Verified public licensing claims.** Dockspace's privacy policy says the app generates a random anonymous identifier, stores it in Keychain, and uses it for license activation and verification. Its EULA says licenses have a device activation limit. Its refund page asks for an invoice and license key and says the Pro license is deactivated after a refund. These are Dockspace's own claims, not an independent audit. [Dockspace privacy policy](https://getdockspace.app/privacy) [Dockspace EULA](https://getdockspace.app/eula) [Dockspace refund policy](https://getdockspace.app/refund)

**Unknown.** Dockspace's public pages do not reveal:

- the trial length or exact start event;
- whether trial state is local, server-issued, or tied to the Keychain identifier;
- what remains usable after expiration;
- whether the app talks directly to Polar or through a Dockspace service;
- how refunds revoke one-time license keys;
- the exact device identifier or activation algorithm;
- whether Dockspace has any separate Mac App Store build.

The public site verifies a direct DMG, Homebrew availability, Polar branding, and the product terms. It does not expose the application implementation. [Dockspace home](https://getdockspace.app/) [Dockspace pricing](https://getdockspace.app/pricing)

## Trial design

### Product behavior

**Recommendation.** Use one full-featured 14-day trial. This duration is a proposed starting point, not a fact learned from Dockspace. Oh My Theme needs enough time for a user to connect several targets, live with a theme, encounter a Light/Dark transition, and try recovery.

Start the trial on the first successful Apply Transaction that changes at least one target. Opening a menu-bar utility or spending time in setup does not prove value. The app already defines a completed transaction and per-target results, so this event has a clear domain meaning. [MVP apply transaction](../architecture/mvp-plan.md#apply-transaction)

Before expiry, show the remaining days in a quiet status row and expose an `Unlock` action. Do not interrupt Apply with recurring modal prompts.

After expiry, switch to safety-preserving read-only mode:

- block new Apply operations and new target connections;
- keep status, previews, reports, license entry, and help available;
- keep Undo Last Theme Change, Restore and Disconnect, and recovery of interrupted work available;
- do not revert a user's current theme merely because the trial expired.

This boundary matters because the app promises guarded rollback and durable recovery. Monetization must never trap user-owned configuration in a managed state. [MVP recovery contract](../architecture/mvp-plan.md#configuration-ownership-and-recovery)

### Entitlement model to add now

Define the business states before adding a provider:

```text
AccessState
  betaAccess
  trial(active: TrialGrant)
  trialExpired(expiredAt)
  licensed(LicenseGrant)
  grace(lastVerifiedAt, endsAt)
  unavailable(reason)
```

Keep these concepts separate:

```text
TrialGrant
  startedAt
  expiresAt
  policyVersion
  lastObservedWallClock

LicenseGrant
  provider
  licenseKeyReference
  activationID
  productBenefitID
  status
  lastVerifiedAt
```

`licenseKeyReference` should point to a Keychain item rather than storing the key in GRDB or logs. Apple's Keychain Services are intended for passwords, keys, and other small secrets. [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)

Add narrow interfaces, not provider types throughout the app:

```text
AccessPolicy
  canPerform(operation, state) -> AccessDecision

TrialStore
  currentGrant() -> TrialGrant?
  startIfNeeded(at) -> TrialGrant
  observeClock(at) -> TrialGrant

LicenseClient
  activate(key, deviceLabel) -> LicenseGrant
  validate(grant) -> LicenseGrant
  deactivate(grant)
```

Place the final authorization check at the engine command boundary immediately before a mutating operation is prepared. The UI should also explain the state, but UI disabling alone is not enforcement.

### Trial persistence and abuse tradeoff

**Recommendation for the first trial release.** Store the trial grant in Keychain and mirror non-secret display metadata in the existing application database. Record the latest observed wall-clock time and refuse to extend the trial when the clock moves backward beyond a small tolerance. Use no email, login, hardware serial number, MAC address, or invasive fingerprint.

**Inference.** A local-only trial is best-effort. A determined user can reset it by deleting local state or changing the application. Stronger enforcement would require a server-issued, signed trial grant tied to a random installation identifier, which adds an online dependency and more privacy work. Accept the local reset risk during product validation. Move to a server-issued trial only if measured abuse justifies operating that service.

## Payment architecture

### Recommended Polar flow

Polar remains the best first provider for this product, but the recommendation is conditional: the business must pass India's onboarding and payout checks, and a qualified Indian CA or lawyer must confirm the intended treatment of Polar's reseller/Merchant of Record structure. Polar combines hosted checkout, Merchant of Record tax handling, one-time digital-product sales, license keys, activation limits, and customer license management. Polar says it is the reseller and handles international sales-tax collection and remittance, while the supplier remains responsible for its own income or revenue tax. That is materially simpler than a processor-only stack, but it is not a general exemption from Indian tax, foreign-exchange, or reporting obligations. [Dockspace pricing](https://getdockspace.app/pricing) [Polar Merchant of Record](https://polar.sh/docs/merchant-of-record/introduction.md) [Polar license keys](https://polar.sh/docs/features/benefits/license-keys.md)

Recommended purchase and activation sequence:

1. Oh My Theme opens a persistent Polar Checkout Link in the default browser. Polar documents checkout links as the simplest hosted flow and supports success and return URLs. [Polar Checkout Links](https://polar.sh/docs/features/checkout/links.md)
2. The user buys a one-time personal license. Attach Polar's license-key benefit to that product and set an initial three-device activation limit.
3. Polar issues the customer a unique license key and exposes it in the customer purchases page. [Polar license keys](https://polar.sh/docs/features/benefits/license-keys.md)
4. The app accepts a pasted key and calls the customer-facing activation endpoint with the public organization ID, a user-editable device label such as `Abdullah's MacBook Pro`, and no hardware fingerprint. [Polar license-key activation example](https://polar.sh/docs/features/benefits/license-keys.md)
5. Verify the returned `organization_id`, `benefit_id`, `status`, activation ID, activation limit, and expiry before granting access. Polar specifically warns sellers to scope validation to the expected benefit when an organization has more than one license-key type. [Polar license-key validation example](https://polar.sh/docs/features/benefits/license-keys.md)
6. Store the license key and activation ID in Keychain. Store only non-secret status and timestamps in GRDB.
7. Validate at activation, at launch when the cached result is older than 24 hours, and before a mutating operation when the cached result is older than 24 hours. Cache a successful perpetual-license result for a 30-day offline grace period.
8. On a definite `revoked`, `disabled`, wrong-organization, or wrong-benefit response, stop new mutations but preserve Undo, Restore and Disconnect. On network failure, use the cached grace period rather than treating the license as revoked.
9. Let users deactivate this Mac and replace the key. Polar also gives customers a portal for deactivating activations and rotating exposed keys. [Polar customer license management](https://polar.sh/docs/features/benefits/license-keys.md)

**Security constraint.** Do not ship a Polar personal or organization access token in the binary. Polar's organization validation endpoint requires `license_keys:write` bearer credentials. Use the customer-facing license flow documented in the license-key guide, or put privileged calls behind a service owned by Oh My Theme. [Polar authenticated validation endpoint](https://polar.sh/docs/api-reference/2026-04/license_keys/validate-license-key.md) [Polar license-key guide](https://polar.sh/docs/features/benefits/license-keys.md)

### Refunds and revocation

**Verified.** Polar emits `order.refunded` and `benefit_grant.revoked` events. Its webhook documentation requires signature validation, retries failed deliveries up to ten times, and recommends quick acknowledgement followed by asynchronous handling. [Polar `order.refunded`](https://polar.sh/docs/api-reference/2026-04/order_refunded.md) [Polar `benefit_grant.revoked`](https://polar.sh/docs/api-reference/2026-04/benefit_grant_revoked.md) [Polar webhook delivery](https://polar.sh/docs/integrate/webhooks/delivery.md)

**Unknown.** The reviewed Polar documentation does not establish that a full refund of a one-time order automatically revokes its license-key benefit. Test this in Polar's sandbox before launch.

**Recommendation.** Start with manual refund review while volume is low. Before promising automatic deactivation, prove the full-refund path in the sandbox. If Polar does not revoke the benefit automatically, add a very small webhook service that validates `order.refunded`, records event IDs idempotently, and disables or revokes the related key through a privileged server-side call. Never put the webhook secret or organization token in the macOS app.

### Provider comparison

| Option | Verified fit | Cost and operational consequence | Decision |
| --- | --- | --- | --- |
| Polar | Merchant of Record/reseller; hosted Checkout Links; one-time digital products; license keys, activation limits, customer deactivation and rotation. India is listed as a supported payout country. [MoR](https://polar.sh/docs/merchant-of-record/introduction.md) [Supported countries](https://polar.sh/docs/merchant-of-record/supported-countries.md) [Payout accounts](https://polar.sh/docs/features/finance/accounts.md) [Checkout](https://polar.sh/docs/features/checkout/links.md) [Licensing](https://polar.sh/docs/features/benefits/license-keys.md) | Starter is 5% + $0.50 per transaction, plus 1.5% for international cards. Payout fees and USD conversion/cross-border costs also apply and should be modelled at the intended price. [Polar fees](https://polar.sh/docs/merchant-of-record/fees.md) [Polar payouts](https://polar.sh/docs/features/finance/payouts.md) | Preferred for a small global direct-sale macOS app, only after India KYC/payout and CA review. |
| Razorpay | India-first payment processor/gateway model (inference from its merchant-account, capture, settlement, and refund docs), with international cards, bank transfers, selected local methods, and UPI. [International payments](https://razorpay.com/docs/payments/international-payments/) [Purpose codes](https://razorpay.com/docs/build/llm-docs/payments/international-payments/purpose-codes.md) [UPI](https://razorpay.com/docs/build/llm-docs/payments/payment-methods/upi.md) | International enablement is subject to KYC, website-policy, banking-partner, and risk approval. Settlements are in INR; pricing for international acceptance is account/product-specific even though standard pricing is commonly published separately. [KYC/setup](https://razorpay.com/docs/build/llm-docs/payments/set-up.md) [Settlements](https://razorpay.com/docs/build/llm-docs/payments/settlements.md) | Best India-local option if UPI/INR settlement and control matter more than MoR convenience. Oh My Theme owns tax/export records, entitlement service, refunds, and disputes. |
| Cashfree | India-first payment processor/gateway model (inference from its merchant-account, order, settlement, refund, and dispute docs). Its International Payment Gateway supports international cards in 140+ currencies; Global Collections supports major foreign-currency collection rails and INR settlement. [IPG](https://www.cashfree.com/docs/payments/international-payments/ipg/overview.md) [Currencies](https://www.cashfree.com/docs/payments/international-payments/ipg/currencies-supported.md) [Global Collections](https://www.cashfree.com/docs/payments/international-payments/global-collections/introduction.md) | Requires a registered Indian business and document review for international products. Standard settlements are to the merchant bank account, typically T+2, with refunds and chargebacks deducted/reconciled by Cashfree. [Global Collections](https://www.cashfree.com/docs/payments/international-payments/global-collections/introduction.md) [Settlements](https://www.cashfree.com/docs/payments/manage/settlements.md) [Disputes](https://www.cashfree.com/docs/payments/manage/disputes/overview.md) | Strong India-local alternative, especially where UPI and INR reconciliation are important; it is not a substitute for a MoR or license system. |
| Stripe India | Stripe's India account is invite-only for registered businesses; it supports international payments, purpose-code onboarding, 135+ currencies for major card networks, and INR payouts. It is a processor/PSP, not a MoR. [Stripe India international payments](https://docs.stripe.com/india-accept-international-payments) | Good international-card and export-control tooling, including 3DS, refunds, and disputes, but the merchant retains tax, export, fulfillment, and license responsibilities. Invite-only status is a material launch risk. [Stripe India international payments](https://docs.stripe.com/india-accept-international-payments) | Middle option if invited and if processor control is worth the extra compliance and licensing work. |
| Lemon Squeezy | Merchant of Record with a License API for activation, validation, and deactivation. [MoR](https://docs.lemonsqueezy.com/help/payments/merchant-of-record) [License API](https://docs.lemonsqueezy.com/api/license-api) | Published base fee is 5% + $0.50, with listed additions including 1.5% for international transactions. [Fees](https://docs.lemonsqueezy.com/help/getting-started/fees) | Fallback if Polar onboarding, India payout support, or sandbox behavior fails the release proof. |
| Mac App Store and StoreKit | Apple supports a non-subscription time trial through a zero-price non-consumable IAP and a full-unlock IAP. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | Requires App Sandbox and StoreKit; conflicts with the current direct-download product and custom license-key workflow. [Repository ADR](../adr/0007-direct-non-sandboxed-distribution.md) | Not suitable for the current product. Treat a future store build as a separate variant. |
| Mac App Store and StoreKit | Apple supports a non-subscription time trial through a zero-price non-consumable IAP named `XX-day Trial`, followed by a full-unlock IAP. [App Review Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/) | Requires App Sandbox, forbids a custom launch-time license screen and license keys, requires App Store updates, and conflicts with the repository's current file and companion workflows. [App Review Guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/) [Repository ADR](../adr/0007-direct-non-sandboxed-distribution.md) | Not suitable for the current product. Treat a future store build as a separate distribution variant. |

## India-specific payment-stack research

Research date: 2026-09-04. This section uses only provider documentation/terms and official Indian government or RBI sources. Provider availability, fees, risk approval, and regulatory rules can change; the linked pages are the authority to re-check before launch.

### Verified India-specific facts

#### Polar

- **Eligibility and KYC:** India is explicitly listed among Polar's supported payout countries. Polar's account-review documentation requires business or personal details, identity verification/KYC, and a connected payout account before going live. Polar says it uses Stripe Connect Express for payout accounts. [Supported countries](https://polar.sh/docs/merchant-of-record/supported-countries.md) [Account reviews](https://polar.sh/docs/merchant-of-record/account-reviews.md) [Payout accounts](https://polar.sh/docs/features/finance/accounts.md)
- **What Polar is:** Polar's Merchant of Record documentation and legal terms describe Polar as the reseller. Polar collects and remits applicable international sales taxes for the customer transaction; Polar separately says the supplier remains responsible for its own income or revenue tax. [MoR introduction](https://polar.sh/docs/merchant-of-record/introduction.md) [Master Services Terms](https://polar.sh/legal/terms)
- **Payouts and currency:** The payout account country must match the business country, and the bank account must be in local currency. Polar converts non-USD order currencies to USD for its balance and generally reports/pays suppliers in USD unless the terms say otherwise. Its payout documentation describes Stripe fees, cross-border conversion charges, a default settlement delay for newer organizations, and a typical 4–7-business-day payout-request time. This makes India payout availability real but not equivalent to an INR settlement account. [Payout accounts](https://polar.sh/docs/features/finance/accounts.md) [Payouts](https://polar.sh/docs/features/finance/payouts.md)
- **Payment methods:** Polar's current product documentation supports one-time digital products and hosted checkout. Polar's changelog says UPI was added for India for INR one-time purchases and recurring subscriptions. Treat UPI as a launch-checkout claim to verify in the actual account and product, not as a universal guarantee. [Products](https://polar.sh/docs/features/products.md) [Polar changelog](https://polar.sh/changelog)
- **Refunds and chargebacks:** Polar documents refunds, `order.refunded`, and benefit-revocation events. Its terms also say the supplier reimburses Polar for refunds, chargebacks, and related fees, and permit reserves or delayed payouts in risk/suspension cases. A one-time license benefit is not proven to revoke automatically for every refund path; keep the existing sandbox gate. [Refunds](https://polar.sh/docs/features/refunds.md) [Webhook events](https://polar.sh/docs/integrate/webhooks/events.md) [Terms](https://polar.sh/legal/terms)

#### Razorpay

- **Eligibility and KYC:** Razorpay's setup documentation supports registered and unregistered business flows and describes PAN, business documents, bank verification, CKYC or document-based verification, and video KYC where needed. Its international-card documentation requires an activated/KYC-approved account, a live website with terms, privacy, refund/cancellation, and shipping policies, plus banking-partner approval. [Account setup and KYC](https://razorpay.com/docs/build/llm-docs/payments/set-up.md) [International cards](https://razorpay.com/docs/build/llm-docs/payments/international-payments/international-debit-credit-cards.md)
- **Cards, UPI, and settlement:** Razorpay documents international debit/credit cards and selected international bank-transfer/local methods, while its regular payment-method documentation includes UPI. Its settlement documentation says settlements are in INR regardless of the customer's payment currency; international payments are converted using the exchange rate at payment creation and the cycle is subject to applicable law and account settings. [International payments](https://razorpay.com/docs/build/llm-docs/payments/international-payments/accept-payments-from-international-customers.md) [UPI](https://razorpay.com/docs/build/llm-docs/payments/payment-methods/upi.md) [Settlements](https://razorpay.com/docs/build/llm-docs/payments/settlements.md)
- **Export records and disputes:** Razorpay requires a purpose code for international enablement and gives software-related examples such as `P0802`, `P0806`, and `P0807`. It provides FIRS statements, source refunds, dispute/chargeback workflows, and settlement reports. [Purpose codes](https://razorpay.com/docs/build/llm-docs/payments/international-payments/purpose-codes.md) [FIRS](https://razorpay.com/docs/build/llm-docs/payments/international-payments/firs-automated-process.md) [Refunds](https://razorpay.com/docs/build/llm-docs/payments/refunds.md) [Disputes](https://razorpay.com/docs/build/llm-docs/payments/disputes.md)

#### Cashfree

- **Eligibility and KYC:** Cashfree's Global Collections documentation says the merchant must be a registered business in India and that document review is required before international activation. The public docs specify the review step but do not settle every sole-proprietor, GSTIN, IEC, or business-category outcome; confirm those during onboarding. [Global Collections](https://www.cashfree.com/docs/payments/international-payments/global-collections/introduction.md) [Hosted checkout prerequisites](https://www.cashfree.com/docs/payments/online/web/redirect.md)
- **Cards, local methods, and payout:** Cashfree's International Payment Gateway documents international cards in 140+ currencies and Pay Native conversion with settlement in INR. Its general hosted checkout documents 120+ payment methods, and its payment-method docs include UPI. Global Collections documents more than 17 currencies, foreign collection rails such as ACH, SEPA, EFT, FPS, and SWIFT, and conversion/settlement to an Indian bank account. These products may have distinct approval, pricing, and reporting behavior. [IPG overview](https://www.cashfree.com/docs/payments/international-payments/ipg/overview.md) [Currencies](https://www.cashfree.com/docs/payments/international-payments/ipg/currencies-supported.md) [Pay Native](https://www.cashfree.com/docs/payments/international-payments/ipg/pay-native.md) [Global Collections accounts](https://www.cashfree.com/docs/payments/international-payments/global-collections/collection-accounts.md) [UPI](https://www.cashfree.com/docs/payments/manage/payment-methods/upi.md)
- **Refunds and chargebacks:** Cashfree provides merchant-initiated full/partial refunds with asynchronous refund webhooks. Its dispute docs require merchants to accept or contest chargebacks and upload evidence within short response windows; unresolved cases can proceed through pre-arbitration or arbitration. [Refunds](https://www.cashfree.com/docs/payments/manage/refunds/overview.md) [Disputes](https://www.cashfree.com/docs/payments/manage/disputes/overview.md)
- **Fulfillment security:** Cashfree requires server-side order creation and secret keys, server-side order-status verification, and webhook confirmation before fulfillment. A direct-download app still needs a server-side entitlement or controlled provider flow; a Cashfree payment success redirect alone is not proof that a license should be issued. [Hosted checkout](https://www.cashfree.com/docs/payments/online/web/redirect.md)

#### Stripe India

Stripe's India documentation says new India accounts are invite-only, Indian businesses cannot simply create a new account through the website, and the supported India business types on that page are registered businesses including sole proprietorships, LLPs, and companies rather than individual-only sellers. Stripe documents export onboarding with a transaction-purpose code and, where applicable, IEC, customer/billing details, and service or item description. It supports INR and non-INR presentment for international customers, 135+ currencies on Visa/Mastercard, and INR payouts to Indian businesses. It also documents 3DS for international card payments plus refunds and disputes. Stripe remains a processor/PSP rather than a Merchant of Record: the merchant still owns its tax, export, fulfillment, refund, dispute, and license responsibilities. [Stripe India: accept international payments](https://docs.stripe.com/india-accept-international-payments)

### GST, export-of-services, FEMA, and reporting caveats

- **GST:** CBIC's official FAQ says exports are zero-rated and specifically answers that a supplier whose outward supplies are all export services needs GST registration to claim refunds. That is useful evidence for a direct Indian seller using a processor, but it is not a complete classification of a downloadable software licence or every registration threshold. [CBIC GST FAQ](https://cbic-gst.gov.in/faq.html)
- **Polar's reseller structure is different:** Polar's contract says Polar is the reseller and handles sales tax for the customer transaction. Whether the Indian supplier's receipt is a supplier payment, commission-like amount, export of service, or another treatment—and which invoices, GST returns, or credits follow—depends on the contract, the actual flow of funds, and current Indian law. Do not assume that a MoR removes Indian GST registration, income-tax, or bookkeeping obligations. Obtain written confirmation from Polar and advice from an Indian CA/lawyer.
- **FEMA and export reporting:** RBI's Master Direction on Export of Goods and Services states that exports of software/services have realization and repatriation requirements, describes online payment gateway arrangements, requires appropriate purpose-code reporting through the authorised-dealer bank, and covers software-export invoicing/reporting procedures. RBI's separate reporting direction says FEMA reports and forms are submitted through authorised persons and that accurate, timely reporting is important. The export direction page fetched for this research is an older consolidated document, so its historical limits and timelines must not be copied into a current launch plan without the business's AD bank/CA confirming the currently applicable rule. [RBI Master Direction—Export of Goods and Services](https://www.rbi.org.in/Scripts/BS_ViewMasDirections.aspx?id=10200) [RBI Master Direction—Reporting under FEMA](https://website.rbi.org.in/web/rbi/-/master-direction-on-reporting-under-fema-1999)
- **Practical reconciliation:** For any processor, retain the checkout/order ID, customer and country data collected lawfully, invoice or receipt, gross and net currency amounts, fees/FX, refund/chargeback outcome, purpose code, payout statement, bank credit/UTR, and any FIRS or equivalent inward-remittance record. For Polar, also retain the supplier statement and contract/tax documents because the customer-facing sale is Polar's reseller transaction. A CA should decide which records support GST, income tax, FEMA/AD-bank, and export reporting positions.
- **India customers:** UPI and INR settlement are not the same question. Polar's UPI claim is account/product dependent; Razorpay and Cashfree document India-local UPI flows more directly. If Indian-customer conversion is a primary objective, test the exact INR/UPI checkout and accounting treatment rather than inferring it from a provider's general international-card documentation.

### License fulfillment implications

Polar is the only compared option in this note whose cited product documentation combines the payment transaction with a digital-product benefit, license-key issuance, activation limits, customer deactivation/rotation, and benefit lifecycle events. Razorpay, Cashfree, and Stripe document payment/order confirmation, refunds, disputes, webhooks, and settlement reporting, but the seller must add the license issuance, activation, revocation, support, and refund-to-entitlement mapping. For the current app, that makes Polar operationally deeper even though it costs more and pays in a USD-oriented supplier flow.

Regardless of provider, never grant a license from a client-side success redirect alone. Use a verified provider event or server-side status, make fulfillment idempotent, record the provider transaction ID, and keep all provider secrets off the macOS binary. For Polar, test whether a full refund revokes the selected one-time benefit; for a processor, plan for a small entitlement service from the beginning.

### Revised recommendation

Use Polar first for international direct-download sales if—and only if—the business completes India KYC and payout onboarding, Polar confirms the intended Indian supplier documentation/settlement flow in writing, and an Indian CA/lawyer reviews GST, income-tax, and FEMA/reporting consequences. Polar is the best fit for this product because it reduces custom commerce and license infrastructure and may provide India UPI, but it has higher fees, USD-oriented supplier accounting, cross-border FX exposure, refund/chargeback pass-through, and reserve/delay risk.

Use Razorpay or Cashfree instead, or as an India-local companion only if UPI/INR conversion, Indian bank reconciliation, or lower processor cost outweighs the need to build and operate tax/export evidence, refund/chargeback handling, and license fulfillment. Consider Stripe India only if an invite is obtained and its international-card/export controls justify the same additional ownership burden.

### Unknowns and launch gates

- [ ] Polar approves the exact India business type, identity/KYC documents, payout account, and bank-currency path.
- [ ] Polar confirms the supplier statement, invoice/receipt, withholding/fees, and records it supplies for an India-based supplier; a CA confirms the corresponding books and returns.
- [ ] Polar confirms whether INR/UPI appears for the intended one-time product and customer locations in the live account.
- [ ] The business's AD bank/CA confirms the current purpose code, export evidence, realization/repatriation, FIRS, SOFTEX/other reporting, and refund treatment for digital software sales.
- [ ] Razorpay and Cashfree confirm the exact merchant category, international-card approval, UPI availability, settlement schedule, pricing, purpose code, and FIRS/e-FIRS artifacts for this business.
- [ ] Stripe invitation and India account approval are obtained before treating Stripe as a real fallback.
- [ ] A sandbox or test-mode purchase proves activation, three-device behavior, offline grace, refund, chargeback/dispute handling, and entitlement revocation.
- [ ] The final choice includes a written refund policy, support route, privacy disclosures, and a server-side fulfillment/reconciliation plan.

## App Store and platform implications

### Current desktop release

**Verified.** This repository builds a macOS-only app, targets macOS 14, disables App Sandbox, and plans direct distribution. There is no web, iOS, iPadOS, Android, or Google Play application in the documented product scope. [README](../../README.md) [Technical stack](../architecture/technical-stack.md#platform)

For direct macOS distribution, the app can use external web checkout and license keys. Before public release it still needs Developer ID signing, Hardened Runtime, notarization, and stapling, as the repository already plans. Apple says Developer ID and a notarization ticket let Gatekeeper verify directly downloaded Mac software. [Repository release plan](../architecture/technical-stack.md#signing-releases-and-updates) [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### If a Mac App Store build is added later

Apple's rules create a separate commerce architecture:

- Apps that unlock app functionality must use In-App Purchase. [Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/)
- A non-subscription app may offer a time trial through a zero-price non-consumable IAP named `XX-day Trial`, with duration and post-trial loss of access disclosed before the trial begins. [Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/)
- Mac App Store apps must be sandboxed and may not present a license screen at launch, require license keys, implement custom copy protection, or use a non-App-Store updater. [Guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/)

**Recommendation.** If this route is ever pursued, compile a separate App Store distribution variant whose `LicenseClient` uses StoreKit and whose adapters satisfy sandbox constraints. Do not put Polar activation in that build. Preserve purchases through StoreKit restoration. Do not try to make one binary switch payment systems at runtime.

### If mobile or web products are added later

**Verified scope statement.** No such products exist in the current repository scope. [Technical stack](../architecture/technical-stack.md#platform)

**Recommendation.** A future iOS or iPadOS app that unlocks Oh My Theme digital functionality should use StoreKit under Guideline 3.1.1 unless a then-current exception applies in its storefront. A browser-only web product can use the direct Polar flow. Google Play policy is not applicable to the present macOS product and should be researched from then-current Google documentation only if an Android product is planned.

## Staged implementation plan

### Stage 0: keep the beta free

1. Leave the current beta in `betaAccess`.
2. Decide the paid product promise, price, personal-device count, refund window, and whether future major versions are included. Dockspace promises all future updates, but that is a business commitment, not an implementation detail. [Dockspace pricing](https://getdockspace.app/pricing)
3. Write the expiration copy and test that recovery operations remain available.

Exit condition: the team can state exactly which operations expire and which safety operations never do.

### Stage 1: ship the provider-neutral trial

1. Add `AccessState`, `AccessPolicy`, `TrialStore`, and a disabled `LicenseClient` seam.
2. Start the 14-day grant after the first successful state-changing Apply Transaction.
3. Persist the grant in Keychain, mirror display state in GRDB, and add basic clock-rollback detection.
4. Gate mutating engine commands, not individual buttons.
5. Add automated tests for first launch, first successful apply, failed apply, expiry, clock rollback, reinstall state where testable, and every recovery operation after expiry.
6. Keep production access in `betaAccess` until the expiration UX passes manual testing, then enable trial policy in a later build.

Exit condition: changing the future billing provider requires only a new `LicenseClient`, not changes to the trial, engine, or recovery model.

### Stage 2: prove Polar without exposing it to users

1. Create a Polar sandbox organization, one-time product, license-key benefit, and Checkout Link.
2. Test one-, three-, and exhausted-activation flows, invalid keys, key rotation, offline launch, and deactivation.
3. Verify which customer-facing endpoint is safe for direct app use and confirm no privileged bearer token is present in the built app.
4. Test full and partial refunds. Record whether and when the key becomes `revoked`.
5. Calculate net proceeds at the intended price, including Polar's fixed fee and international-card addition. [Polar fees](https://polar.sh/docs/merchant-of-record/fees.md)

Exit condition: a sandbox purchase can activate a clean build, a second Mac behaves as specified, and a full refund reaches the intended access state.

### Stage 3: enable one-time purchases

1. Open the hosted checkout in the default browser.
2. Add `Enter license key`, `Deactivate this Mac`, `Manage license`, and `Buy license` actions.
3. Validate licenses against the expected organization and benefit IDs.
4. Cache successful validation for offline use and use a 30-day grace period for network failures.
5. Publish accurate privacy, license, refund, and support pages. Distinguish data processed by the app from data collected by the payment provider.
6. Sign, harden, notarize, and staple the release before distribution. [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Exit condition: purchase, activation, offline grace, deactivation, rotation, refund, recovery, and clean-machine installation all pass manual verification.

### Stage 4: add a service only if needed

Add a minimal entitlement service if trial-reset abuse is material, automatic refund revocation cannot be achieved through Polar alone, or support needs remote entitlement repair. Its jobs should stay narrow:

- issue signed anonymous trial grants;
- validate Polar webhook signatures and process event IDs idempotently;
- map full refunds to license revocation when Polar does not do so;
- issue short signed entitlement receipts for offline verification.

Do not add accounts, profiles, cloud workspace state, or telemetry merely because this service exists. The current product excludes cloud sync and background telemetry. [MVP exclusions](../architecture/mvp-plan.md#excluded-from-the-beta)

## Release checklist and unresolved decisions

Resolve these before enabling paid access:

- [ ] Trial duration accepted. This note proposes 14 days; Dockspace's duration is unknown.
- [ ] Trial start accepted. This note proposes first successful state-changing apply.
- [ ] Expired-mode operation matrix approved, with all recovery actions left available.
- [ ] Price and included update term approved.
- [ ] Personal license device count approved. This note proposes three Macs.
- [ ] Polar India seller eligibility, KYC, payout account, settlement currency, and supplier documentation verified in the live onboarding flow.
- [ ] Polar full-refund behavior for one-time license benefits proven in sandbox.
- [ ] Offline grace duration approved. This note proposes 30 days.
- [ ] Privacy copy reviewed. Do not repeat Dockspace's claims without checking what Oh My Theme and Polar actually process.
- [ ] Legal terms and refund policy reviewed by qualified counsel where required. This research is an engineering and product recommendation, not legal advice.

## Final recommendation in one sentence

Ship a full-featured, locally persisted 14-day trial behind a provider-neutral engine-level access policy now, then prefer a directly distributed one-time Polar license with three device activations, browser checkout, Keychain storage, periodic validation, and recovery-safe expiration only after India onboarding/payout approval, CA/lawyer review of the Indian treatment, and sandbox proof of activation and refund behavior; use Razorpay or Cashfree when India-local UPI/INR control is the overriding requirement.
