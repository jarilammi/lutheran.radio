//
//  LanguageSelectorView.swift
//  Lutheran Radio
//
//  Encapsulates the custom horizontal flag "radio tuning" selector + red needle indicator
//  and all associated layout math, animations, and collection view management.
//
//  Created by Jari Lammi on 12.6.2026.
//

import UIKit

/// Self-contained custom view that renders the horizontal language/flag selector
/// (UICollectionView of LanguageCell) plus the animated red "tuning needle" (selectionIndicator).
///
/// Responsibilities (moved verbatim from ViewController):
/// - Creation and configuration of the internal collection view and needle.
/// - All needle positioning math: centerCollectionViewContent, centerXForIndex, updateSelectionIndicator
///   (dual-path: layoutAttributes when available + pure-math fallback; sectionInset centering;
///    epsilon skip; isInitial fast-path; pulse animation).
/// - UICollectionViewDataSource / Delegate / FlowLayout conformance for the flags.
/// - Internal rotation and initial-scroll guard state.
/// - Notification of user selection via closure (owner retains all optimistic prePlay / stream switch / intent logic).
///
/// The view is driven by the owner:
/// - Owner supplies authoritative selected index via `setSelectedIndex(...)`.
/// - Owner receives taps via `onSelectionChanged`.
/// - Owner forwards width-driven layout changes via `notifyLayoutChange(currentSelectedIndex:)`.
///
/// All observable needle behavior, cold-launch positioning, stream-switch sweeps, and rotation handling
/// must remain pixel- and timing-identical to the previous monolithic implementation.
@MainActor
final class LanguageSelectorView: UIView, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    // MARK: - Owner callback (selection intent only; no decision logic here)
    /// Called when the user taps a flag cell. The owner performs optimistic prePlay,
    /// stream-switch debouncing, completeStreamSwitch, SharedPlayerManager routing, etc.
    var onSelectionChanged: ((Int) -> Void)?

    // MARK: - Internal UI (encapsulated; never exposed to owner)
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 10   // horizontal gap between flags (the value the centering math must match)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .systemBackground
        cv.isAccessibilityElement = false // Prevent the collection view itself from being focused; cells are accessible
        cv.accessibilityTraits = .none
        cv.contentInsetAdjustmentBehavior = .never   // Important: sectionInset alone must control centering; default .automatic injects safe-area insets that break the math
        return cv
    }()

    private let selectionIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemRed.withAlphaComponent(0.7)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = false
        return view
    }()

    // MARK: - State moved from ViewController (verbatim)
    private var lastCollectionViewSize: CGSize = .zero
    private var isRotating = false
    private var lastRotationTime: Date? // To debounce rapid rotations
    private let rotationDebounceInterval: TimeInterval = 0.5 // 500ms
    private var isInitialScrollLocked = true
    private var didPositionNeedle = false
    /// Needle X is already correct within this many points — skip redundant layout/appear updates.
    private let selectionIndicatorPositionEpsilon: CGFloat = 0.5
    private var pendingStreamIndex: Int?

    /// Drives the tuning needle X position via Auto Layout so layout passes do not override it.
    private var needleCenterXConstraint: NSLayoutConstraint?

    // MARK: - Initialization
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setupCollectionView()
        setupSelectionIndicator()
        scheduleInitialScrollUnlock()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCollectionView() {
        addSubview(collectionView)

        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(LanguageCell.self, forCellWithReuseIdentifier: "LanguageCell")
        collectionView.bounces = false
        collectionView.isScrollEnabled = false

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupSelectionIndicator() {
        // The indicator lives inside the collection view so it participates in the same coordinate system
        // and can be brought in front of the flag cells.
        collectionView.addSubview(selectionIndicator)
        collectionView.bringSubviewToFront(selectionIndicator)

        NSLayoutConstraint.activate([
            selectionIndicator.widthAnchor.constraint(equalToConstant: 4),
            selectionIndicator.heightAnchor.constraint(equalTo: collectionView.heightAnchor, multiplier: 0.8),
            selectionIndicator.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor)
        ])

        // Create the horizontal position constraint for the tuning needle once.
        // We update its .constant in updateSelectionIndicator instead of mutating .center.x.
        needleCenterXConstraint = selectionIndicator.centerXAnchor.constraint(equalTo: collectionView.leadingAnchor, constant: 0)
        needleCenterXConstraint?.isActive = true
    }

    private func scheduleInitialScrollUnlock() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isInitialScrollLocked = false
        }
    }

    // MARK: - Public driving API (used by ViewController)

    /// Reloads the flag cells from DirectStreamingPlayer.availableStreams.
    func reloadData() {
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
    }

    /// Drives selection + needle positioning from the owner (the authoritative selectedStreamIndex lives in ViewController).
    /// This replaces all previous direct calls to selectItem + updateSelectionIndicator + centerCollectionViewContent.
    func setSelectedIndex(
        _ index: Int,
        isInitial: Bool = false,
        animated: Bool = false,
        animationDuration: TimeInterval? = nil,
        caller: String = #function
    ) {
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectItem(at: indexPath, animated: animated, scrollPosition: .centeredHorizontally)
        updateSelectionIndicator(
            to: index,
            isInitial: isInitial,
            caller: caller,
            animationDuration: animationDuration
        )
    }

    /// Called by owner from viewDidLayoutSubviews when the available width may have changed.
    /// The internal lastCollectionViewSize guard + needle recenter lives here.
    func notifyLayoutChange(currentSelectedIndex index: Int) {
        if collectionView.frame.width != lastCollectionViewSize.width {
            updateSelectionIndicator(to: index, isInitial: false, caller: "notifyLayoutChange")
            lastCollectionViewSize = collectionView.frame.size
        }
    }

    // MARK: - Needle math (moved verbatim from ViewController + SAFETY comment)

    // SAFETY / moved from ViewController: needle positioning math is extremely sensitive.
    // Preserved verbatim (dual layoutAttributes + pure centerXForIndex fallback, sectionInset mutation in
    // centerCollectionViewContent, epsilon skip, isInitial fast path, 0-duration initial, pulse animation on
    // non-initial sweeps, caller tagging for debug, all early-return guards).
    // This guarantees identical needle position and animation behavior on cold launch, stream switch,
    // rotation, and dynamic width changes. See viewcontroller-decomposition-prompt.txt for extraction history.
    private func centerCollectionViewContent() {
        guard collectionView.bounds.width > 0, DirectStreamingPlayer.availableStreams.count > 0 else {
            #if DEBUG
            print("[LanguageSelectorView] centerCollectionViewContent: Invalid bounds or no streams, width=\(collectionView.bounds.width)")
            #endif
            return
        }
        collectionView.layoutIfNeeded()
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            #if DEBUG
            print("[LanguageSelectorView] centerCollectionViewContent: Invalid layout, aborting")
            #endif
            return
        }
        // Read the actual configured values so the centering math always matches what the layout will draw.
        let totalItems = DirectStreamingPlayer.availableStreams.count
        let cellWidth = layout.itemSize.width
        let spacing = layout.minimumInteritemSpacing
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = collectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        layout.invalidateLayout()

        #if DEBUG
        print("[LanguageSelectorView] centerCollectionViewContent: totalCellWidth=\(totalCellWidth), collectionViewWidth=\(collectionViewWidth), inset=\(inset), bounds=\(collectionView.bounds)")
        #endif
    }

    /// Pure mathematical derivation of the tuning needle (selectionIndicator) center X.
    /// Mirrors the exact 50pt/10pt/inset formula from centerCollectionViewContent so we are
    /// independent of UICollectionView layoutAttributes timing during cold-start metadata storms
    /// and orientation changes.
    private func centerXForIndex(_ index: Int) -> CGFloat {
        let totalItems = DirectStreamingPlayer.availableStreams.count
        guard collectionView.bounds.width > 0, totalItems > 0 else {
            return collectionView.bounds.midX
        }
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            return collectionView.bounds.midX
        }
        let safeIndex = min(max(index, 0), totalItems - 1)
        // Derive from the live layout configuration (set in one place + delegate) so the
        // needle math always matches the actual cell positions the collection view will draw.
        let cellWidth = layout.itemSize.width
        let spacing = layout.minimumInteritemSpacing
        let totalCellWidth = (cellWidth * CGFloat(totalItems)) + (spacing * CGFloat(totalItems - 1))
        let collectionViewWidth = collectionView.bounds.width
        let inset = max((collectionViewWidth - totalCellWidth) / 2, 0)
        let rawCenter = inset + (cellWidth / 2) + (CGFloat(safeIndex) * (cellWidth + spacing))
        // Safe half-width even if the indicator frame hasn't been sized yet
        let halfWidth = max(selectionIndicator.frame.width / 2, 2)
        let minX = halfWidth
        let maxX = collectionViewWidth - halfWidth
        return max(minX, min(maxX, rawCenter))
    }

    // MARK: - Selection Indicator (moved verbatim)

    private func updateSelectionIndicator(
        to index: Int,
        isInitial: Bool = false,
        caller: String = #function,
        animationDuration: TimeInterval? = nil
    ) {
        // SINGLE SOURCE OF TRUTH
        // • During normal operation (pause, play, network hiccups, etc.) → always use the index passed by owner
        // • Only on true initial load → accept the passed index
        let targetIndex = index

        // Safety guard
        let safeIndex = min(max(targetIndex, 0), DirectStreamingPlayer.availableStreams.count - 1)

        #if DEBUG
        print("[LanguageSelectorView] updateSelectionIndicator: Moving to index=\(safeIndex) (isInitial=\(isInitial), caller=\(caller))")
        #endif

        guard safeIndex >= 0 && safeIndex < DirectStreamingPlayer.availableStreams.count else {
            #if DEBUG
            print("[LanguageSelectorView] updateSelectionIndicator: Invalid index \(safeIndex), streams count=\(DirectStreamingPlayer.availableStreams.count)")
            #endif
            return
        }

        // Needle constraints are set once in setup. Never re-parent or re-activate them here.
        // Repeated addSubview + NSLayoutConstraint.activate creates duplicate/ambiguous constraints
        // that conflict with the manual .center.x mutation and cause the needle to drift or snap.
        if selectionIndicator.superview != collectionView {
            collectionView.addSubview(selectionIndicator)
            selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
            // constraints intentionally NOT re-activated here
        }

        // Important for fault tolerance:
        // Always re-apply the centering insets before we compute or trust anything.
        // This guarantees the same math that positions the cells is active.
        centerCollectionViewContent()
        collectionView.layoutIfNeeded()

        let indexPath = IndexPath(item: safeIndex, section: 0)

        // Prefer the *actual* cell center from the layout engine. This guarantees the needle
        // sits on the real flag cell no matter what effective insets or timing the collection
        // view is using. Fall back to the pure math only if attributes are not available yet.
        let cellCenterX: CGFloat
        if let layoutAttributes = collectionView.layoutAttributesForItem(at: indexPath) {
            let cellFrame = layoutAttributes.frame
            cellCenterX = cellFrame.midX
            #if DEBUG
            let derived = centerXForIndex(safeIndex)
            print("[LanguageSelectorView] updateSelectionIndicator: Moving to index=\(safeIndex), using actual midX=\(cellCenterX) (derived was \(derived), delta=\(cellCenterX - derived)), cellFrame=\(cellFrame), bounds=\(collectionView.bounds), isInitial=\(isInitial), caller=\(caller)")
            #endif
        } else {
            cellCenterX = centerXForIndex(safeIndex)
            #if DEBUG
            print("[LanguageSelectorView] updateSelectionIndicator: No layout attributes for indexPath=\(indexPath) — falling back to derived centerX=\(cellCenterX)")
            #endif
        }

        // Skip if the collection view has no width yet (still early in layout)
        guard collectionView.bounds.width > 0 else {
            #if DEBUG
            print("[LanguageSelectorView] updateSelectionIndicator: Skipping — collection view has zero width")
            #endif
            needleCenterXConstraint?.constant = cellCenterX
            return
        }

        let currentNeedleX = needleCenterXConstraint?.constant ?? selectionIndicator.center.x
        if abs(currentNeedleX - cellCenterX) <= selectionIndicatorPositionEpsilon {
            #if DEBUG
            print("[LanguageSelectorView] updateSelectionIndicator: Skipping — already at target X=\(cellCenterX) (caller=\(caller))")
            #endif
            return
        }

        let duration = animationDuration ?? (isInitial ? 0.0 : 0.3)
        let usesNeedlePulse = !isInitial && duration > 0
        UIView.animate(withDuration: duration) {
            self.needleCenterXConstraint?.constant = cellCenterX
            self.collectionView.layoutIfNeeded()
            self.selectionIndicator.transform = usesNeedlePulse ? CGAffineTransform(scaleX: 1.5, y: 1.0) : .identity
        } completion: { _ in
            if usesNeedlePulse {
                UIView.animate(withDuration: 0.1) {
                    self.selectionIndicator.transform = .identity
                }
            }
            self.didPositionNeedle = true
            #if DEBUG
            print("[LanguageSelectorView] updateSelectionIndicator: Animation completed, final center.x=\(self.selectionIndicator.center.x) (didPositionNeedle=true)")
            #endif
        }
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        DirectStreamingPlayer.availableStreams.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LanguageCell", for: indexPath) as? LanguageCell else {
            fatalError("Failed to dequeue LanguageCell — check cell registration and identifier")
        }

        let stream = DirectStreamingPlayer.availableStreams[indexPath.item]
        cell.configure(with: stream)
        return cell
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isRotating else {  // Suppress during rotation
            #if DEBUG
            print("[LanguageSelectorView] Suppressed didSelect during rotation")
            #endif
            return
        }

        let newIndex = indexPath.item

        #if DEBUG
        print("[LanguageSelectorView] collectionView:didSelectItemAt called for index \(newIndex)")
        #endif

        // Notify owner. All optimistic prePlay, SharedPlayerManager routing, debounce,
        // tuning sound coordination, and completeStreamSwitch logic remains in the owner
        // (ViewController) per the decomposition plan.
        onSelectionChanged?(newIndex)
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cellWidth: CGFloat = 50
        #if DEBUG
        print("[LanguageSelectorView] Cell size for item \(indexPath.item): width = \(cellWidth), height = 50")
        #endif
        return CGSize(width: cellWidth, height: 50)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        let spacing = 10.0
        #if DEBUG
        print("[LanguageSelectorView] Minimum line spacing for section \(section): \(spacing)")
        #endif
        return spacing
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        // Horizontal spacing between items in the horizontal flag row.
        // Must match layout.minimumInteritemSpacing and the centering math.
        let spacing: CGFloat = 10.0
        #if DEBUG
        print("[LanguageSelectorView] Minimum inter-item spacing for section \(section): \(spacing)")
        #endif
        return spacing
    }
}
