#if os(iOS)
import XCTest
import CoreGraphics

@testable import ConchTalk

final class BubbleGestureStateMachineTests: XCTestCase {
    func test_gestureEnabled_keyboardVisible_returnsFalse() {
        XCTAssertFalse(
            BubbleGestureReducer.gestureEnabled(
                canTriggerContextBreak: true,
                isKeyboardVisible: true
            )
        )
    }

    func test_gestureEnabled_keyboardHidden_reflectsContextBreakAvailability() {
        XCTAssertTrue(
            BubbleGestureReducer.gestureEnabled(
                canTriggerContextBreak: true,
                isKeyboardVisible: false
            )
        )
        XCTAssertFalse(
            BubbleGestureReducer.gestureEnabled(
                canTriggerContextBreak: false,
                isKeyboardVisible: false
            )
        )
    }

    func test_noDragging_positiveOverscroll_keepsIdle() {
        let state = BubbleGestureReducer.reduce(
            phase: .idle,
            isDragging: false,
            isNearBottom: true,
            overscroll: 18,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .idle)
    }

    func test_draggingBelowDisplayThreshold_keepsIdle() {
        let state = BubbleGestureReducer.reduce(
            phase: .idle,
            isDragging: true,
            isNearBottom: true,
            overscroll: 3,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .idle)
    }

    func test_draggingAboveDisplayThreshold_entersPulling() {
        let overscroll: CGFloat = 40
        let state = BubbleGestureReducer.reduce(
            phase: .idle,
            isDragging: true,
            isNearBottom: true,
            overscroll: overscroll,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .pulling(progress: overscroll / BubblePullInteraction.armedOverscrollPoints))
    }

    func test_draggingUpperThreshold_entersArmed() {
        let state = BubbleGestureReducer.reduce(
            phase: .idle,
            isDragging: true,
            isNearBottom: true,
            overscroll: BubblePullInteraction.armedOverscrollPoints,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .armed)
    }

    func test_armed_geometryChanged_staysArmed() {
        let state = BubbleGestureReducer.reduce(
            phase: .armed,
            isDragging: false,
            isNearBottom: true,
            overscroll: 0,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .armed)
    }

    func test_armed_dragging_belowThreshold_returnsToPulling() {
        let overscroll: CGFloat = 40
        let state = BubbleGestureReducer.reduce(
            phase: .armed,
            isDragging: true,
            isNearBottom: true,
            overscroll: overscroll,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(state.phase, .pulling(progress: overscroll / BubblePullInteraction.armedOverscrollPoints))
    }

    func test_enteringArmed_geometryChanged_triggersReadyHapticOnce() {
        let entering = BubbleGestureReducer.reduce(
            phase: .pulling(progress: 0.6),
            isDragging: true,
            isNearBottom: true,
            overscroll: BubblePullInteraction.armedOverscrollPoints + 8,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertEqual(entering.phase, .armed)
        XCTAssertTrue(entering.shouldFireReadyHaptic)

        let repeated = BubbleGestureReducer.reduce(
            phase: entering.phase,
            isDragging: true,
            isNearBottom: true,
            overscroll: BubblePullInteraction.armedOverscrollPoints + 12,
            canTrigger: true,
            event: .geometryChanged
        )

        XCTAssertFalse(repeated.shouldFireReadyHaptic)
    }

    #if os(iOS)
    func test_retractingDisplayState_prefersRetractingProgress() {
        let state = ChatMessageListView.bubbleDisplayState(
            phase: .retracting(from: 0.8),
            retractingProgress: 0.2
        )

        XCTAssertEqual(state, .pulling(offset: 0.2 * BubblePullInteraction.armedOverscrollPoints))
    }
    #endif

    func test_pulling_dragEnded_entersRetracting() {
        let phase = BubbleGesturePhase.pulling(progress: 0.4)
        let state = BubbleGestureReducer.reduce(
            phase: phase,
            isDragging: false,
            isNearBottom: true,
            overscroll: 40,
            canTrigger: true,
            event: .dragEnded
        )

        XCTAssertEqual(state.phase, .retracting(from: 0.4))
    }

    func test_armed_dragEnded_entersBurst() {
        let state = BubbleGestureReducer.reduce(
            phase: .armed,
            isDragging: false,
            isNearBottom: true,
            overscroll: 90,
            canTrigger: true,
            event: .dragEnded
        )

        XCTAssertEqual(state.phase, .burst)
    }

    func test_armed_dragEnded_triggersContextBreak() {
        let state = BubbleGestureReducer.reduce(
            phase: .armed,
            isDragging: false,
            isNearBottom: true,
            overscroll: 90,
            canTrigger: true,
            event: .dragEnded
        )

        XCTAssertTrue(state.shouldTriggerContextBreak)
    }

    func test_pulling_dragEnded_doesNotTriggerContextBreak() {
        let state = BubbleGestureReducer.reduce(
            phase: .pulling(progress: 0.5),
            isDragging: false,
            isNearBottom: true,
            overscroll: 40,
            canTrigger: true,
            event: .dragEnded
        )

        XCTAssertFalse(state.shouldTriggerContextBreak)
    }

    func test_retracting_animationCompleted_returnsIdle() {
        let state = BubbleGestureReducer.reduce(
            phase: .retracting(from: 0.6),
            isDragging: false,
            isNearBottom: true,
            overscroll: 0,
            canTrigger: true,
            event: .animationCompleted
        )

        XCTAssertEqual(state.phase, .idle)
    }

    func test_burst_animationCompleted_returnsIdle() {
        let state = BubbleGestureReducer.reduce(
            phase: .burst,
            isDragging: false,
            isNearBottom: true,
            overscroll: 0,
            canTrigger: true,
            event: .animationCompleted
        )

        XCTAssertEqual(state.phase, .idle)
    }
}
#endif
