import Observation
import ArkenalKit
import StoreKit

/// Arkenal Pro: one non-consumable purchase, shared across iPhone, iPad and
/// Mac (universal purchase) and with Family Sharing. The App Store's
/// current entitlements are the source of truth; the result is also kept in
/// the app group so the Finder extension and quick checks can read it.
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()
    static let productID = "com.snowlightlabs.arkenal.pro"

    private(set) var isUnlocked = SharedContainer.isProUnlocked
    private(set) var product: Product?
    private(set) var isPurchasing = false
    var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {}

    /// Quick check from anywhere (cached; refreshed from the App Store at launch).
    nonisolated static var unlocked: Bool { SharedContainer.isProUnlocked }

    /// At launch: load the product, check entitlements, and listen for
    /// purchases made elsewhere (another device, Family Sharing, Ask to Buy).
    func start() {
        guard updates == nil else { return }
        #if DEBUG
        // `-pro` unlocks everything, for testing and screenshots.
        if CommandLine.arguments.contains("-pro") {
            set(true)
            return
        }
        #endif
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case let .verified(transaction) = update {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
        Task {
            product = try? await Product.products(for: [Self.productID]).first
            await refresh()
        }
    }

    func refresh() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case let .verified(transaction) = entitlement, transaction.productID == Self.productID, transaction.revocationDate == nil {
                owned = true
            }
        }
        set(owned)
    }

    func purchase() async {
        guard let product, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                await transaction.finish()
                set(true)
            case .success(.unverified):
                message = "The purchase couldn't be verified. Try Restore Purchases."
            case .pending:
                message = "Waiting for approval. Arkenal Pro unlocks when it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through. Try again."
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
        if !isUnlocked { message = "No Arkenal Pro purchase was found for this Apple Account." }
    }

    private func set(_ owned: Bool) {
        isUnlocked = owned
        SharedContainer.isProUnlocked = owned
    }
}
