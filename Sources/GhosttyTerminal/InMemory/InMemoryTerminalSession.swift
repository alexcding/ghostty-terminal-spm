//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private static let slowSurfaceWriteThreshold: TimeInterval = 0.5

    private let resizeLock = NSLock()
    private let surfaceAccess: InMemoryTerminalSurfaceAccess
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void
    private let appearanceHandler: @Sendable ([UInt32]) -> Void

    /// Skip resize dispatches whose grid is unchanged and only the pixel
    /// metrics moved.
    ///
    /// Off by default: the resize closure is a lossless contract, and a host
    /// that reads `widthPixels`/`heightPixels` would otherwise stop seeing
    /// sub-cell changes — permanently, if the grid never changes again.
    ///
    /// Worth enabling for a host that only consumes columns and rows and
    /// repaints on every dispatch. A live divider drag produces mostly
    /// pixel-only updates (measured at ~78% of metric updates across one
    /// session's drags), and each one asks the terminal app for a full
    /// repaint that re-wraps its content.
    public let suppressesPixelOnlyResizes: Bool
    private var usesGeometryCallbacks = false

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
        appearance: @escaping @Sendable ([UInt32]) -> Void = { _ in },
        suppressesPixelOnlyResizes: Bool = false
    ) {
        writeHandler = write
        resizeHandler = resize
        appearanceHandler = appearance
        self.suppressesPixelOnlyResizes = suppressesPixelOnlyResizes
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: Self.writeToSurface,
            processExit: Self.reportProcessExit,
            tick: Self.tickApp
        )
    }

    /// Test seam: the surface handed to `setSurface` is a stand-in, so every
    /// C call on it is injected, and the tick defaults to a no-op.
    init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
        suppressesPixelOnlyResizes: Bool = false,
        surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write,
        processExit: @escaping InMemoryTerminalSurfaceAccess.ProcessExit =
            InMemoryTerminalSession.reportProcessExit,
        tick: @escaping InMemoryTerminalSurfaceAccess.Tick = { _ in }
    ) {
        writeHandler = write
        resizeHandler = resize
        appearanceHandler = { _ in }
        self.suppressesPixelOnlyResizes = suppressesPixelOnlyResizes
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: surfaceWrite,
            processExit: processExit,
            tick: tick
        )
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        surfaceAccess.setSurface(surface)
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        guard surfaceAccess.clearSurface(ifMatches: expectedSurface) else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surfaceAccess.currentSurface == nil ? "nil" : "set")"
            )
            return
        }

        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        surfaceAccess.currentSurface
    }

    /// Imports initial state and its logical grid into a fresh surface.
    /// Call before exposing the surface to user input or sending live output.
    /// Invalid snapshots and non-fresh surfaces are left unchanged.
    @MainActor
    @discardableResult
    public func restoreSnapshot(_ snapshot: Data) -> Bool {
        guard !snapshot.isEmpty, snapshot.count <= 192 * 1024 * 1024 else { return false }
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            snapshot.withUnsafeBytes { bytes in
                guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return ghostty_surface_restore_snapshot(surface, pointer, UInt(bytes.count))
            }
        } ?? false
    }

    /// The version of the actual linked renderer, used for shell identity.
    public static var runtimeVersion: String? {
        let info = ghostty_info()
        guard let version = info.version, info.version_len > 0, info.version_len <= 128 else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: version, count: Int(info.version_len)), encoding: .utf8)
    }

    /// Enable daemon-identity-v1 (state plus DA/version/terminfo replies).
    /// Requires an imported surface with the default clipboard-write policy.
    @MainActor
    public func enableHostIdentityResponses() -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_enable_host_identity_responses(surface)
        } ?? false
    }

    /// Receive complete engine-ordered geometry, including cell pixels. The
    /// resize handler must only enqueue host work and never re-enter a surface.
    @MainActor
    public func enableGeometryCallbacks() -> Bool {
        surfaceAccess.withCurrentSurface { surface in
            resizeLock.lock(); usesGeometryCallbacks = true; resizeLock.unlock()
            let enabled = ghostty_surface_set_host_geometry_callback(surface, Self.receiveGeometryCallback)
            if !enabled {
                resizeLock.lock(); usesGeometryCallbacks = false; resizeLock.unlock()
            }
            return enabled
        } ?? false
    }

    /// Callback data is already copied; handlers may enqueue host work only.
    @MainActor
    public func enableAppearanceCallbacks() -> Bool {
        surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_set_host_appearance_callback(surface, Self.receiveAppearanceCallback)
        } ?? false
    }
    @MainActor
    public func enableHostAppearanceResponses() -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { ghostty_surface_enable_host_appearance_responses($0) } ?? false
    }
    public func applyHostAppearance(_ values: [UInt32]) -> Bool {
        guard values.count == 260 else { return false }
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            values.withUnsafeBufferPointer { buffer in
                ghostty_surface_apply_host_appearance(surface, buffer.baseAddress!, buffer.count)
            }
        } ?? false
    }
    static let receiveAppearanceCallback: ghostty_surface_host_appearance_cb = { userdata, values, count in
        guard let userdata, let values, count == 260 else { return }
        let session = Unmanaged<InMemoryTerminalSession>.fromOpaque(userdata).takeUnretainedValue()
        session.appearanceHandler(Array(UnsafeBufferPointer(start: values, count: Int(count))))
    }

    /// Enable daemon-geometry-graphics-v2 (identity/state plus pixel size reports).
    /// Requires complete imported pixel metrics and the native clipboard policy.
    @MainActor
    public func enableHostGeometryResponses() -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_enable_host_geometry_responses(surface)
        } ?? false
    }

    /// Enable daemon-state-v1 after snapshot import, before metadata/live output.
    /// The daemon must own this exact query set for the shell's whole lifetime.
    @MainActor
    public func enableHostStateResponses() -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_enable_host_state_responses(surface)
        } ?? false
    }

    /// Publish imported title/pwd using native validation, without VT replay.
    /// Call on a worker before feeding live output; the UI must keep ticking.
    public func publishSnapshotMetadata() -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_publish_snapshot_metadata(surface)
        } ?? false
    }

    /// Deliver queued metadata outside a surface operation. Callbacks may close
    /// the surface, so ticking while holding an operation would deadlock teardown.
    @MainActor
    public func flushSnapshotMetadataCallbacks() -> Bool {
        guard let surface = surfaceAccess.currentSurface else { return false }
        Self.tickApp(surface)
        return surfaceAccess.currentSurface != nil
    }

    /// Apply a daemon-ordered grid change after prior host output has drained.
    /// The caller serializes this method with receive calls for the same session.
    public func applyHostGridSize(columns: UInt16, rows: UInt16) -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_apply_host_grid_size(surface, columns, rows)
        } ?? false
    }

    /// Apply the daemon's ordered cell/pixel geometry. Physical view layout
    /// continues to use this surface's font metrics, without writing a reply.
    public func applyHostGeometry(columns: UInt16, rows: UInt16, cellWidthPixels: UInt32, cellHeightPixels: UInt32) -> Bool {
        surfaceAccess.waitForPendingOutput()
        return surfaceAccess.withCurrentSurface { surface in
            ghostty_surface_apply_host_geometry(surface, columns, rows, cellWidthPixels, cellHeightPixels)
        } ?? false
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached: one line per viewport row, joined with `\n`. The
    /// `ghostty_text_s` lifecycle (allocate via `ghostty_surface_read_text`,
    /// free via `ghostty_surface_free_text`) is fully encapsulated — callers
    /// never touch the C buffer.
    ///
    /// Each row is its own read, `(VIEWPORT, EXACT (0, y))` to
    /// `(VIEWPORT, EXACT (columns - 1, y))`: a single read over the whole
    /// viewport unwraps a soft-wrapped row into its neighbour's line, and
    /// `TerminalSelectionAnchor` indexes these lines by viewport row. This
    /// reads exactly the visible rows and ignores scrollback. Empty viewports
    /// return an empty string.
    ///
    /// Thread-safe: keeps the surface alive for the duration of the read,
    /// preventing access against a surface mid-replacement.
    public func readViewportText() -> String? {
        surfaceAccess.withCurrentSurface { surface -> String? in
            let size = ghostty_surface_size(surface)
            guard size.columns > 0 else { return "" }
            var lines: [String] = []
            for row in 0..<UInt32(size.rows) {
                let selection = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_EXACT,
                        x: 0,
                        y: row
                    ),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_EXACT,
                        x: UInt32(size.columns) - 1,
                        y: row
                    ),
                    rectangle: false
                )

                var out = ghostty_text_s()
                guard ghostty_surface_read_text(surface, selection, &out) else {
                    return nil
                }
                defer { ghostty_surface_free_text(surface, &out) }

                guard let textPtr = out.text, out.text_len > 0 else {
                    lines.append("")
                    continue
                }
                let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                    .map { UInt8(bitPattern: $0) }
                lines.append(String(decoding: bytes, as: UTF8.self))
            }
            return lines.joined(separator: "\n")
        } ?? nil
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Enqueue data for the terminal from the host backend.
    ///
    /// Writes are processed in order on a per-session serial queue so parsing
    /// cannot block the caller or the main thread. Bytes that arrive before a
    /// surface attaches are buffered (oldest dropped past a 1 MiB cap) and
    /// flushed on attach — hosts do not need to hold their connection until
    /// the first viewport report.
    public func receive(_ data: Data) {
        surfaceAccess.enqueueWrite(data)
        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Enqueue a host-managed process exit after all previously received data.
    /// Like that data, an exit that arrives before a surface attaches waits
    /// for the next one and is delivered after the buffered bytes.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        surfaceAccess.enqueueProcessExit(
            exitCode: exitCode,
            runtimeMilliseconds: runtimeMilliseconds
        )
        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        session.resizeLock.lock()
        let legacy = !session.usesGeometryCallbacks
        session.resizeLock.unlock()
        guard legacy else { return }
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ), legacy: true)
    }

    static let receiveGeometryCallback: ghostty_surface_host_geometry_cb = { userdata, cols, rows, width, height, cellWidth, cellHeight in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>.fromOpaque(userdata).takeUnretainedValue()
        session.dispatchResize(InMemoryTerminalViewport(columns: cols, rows: rows,
            widthPixels: width, heightPixels: height, cellWidthPixels: cellWidth, cellHeightPixels: cellHeight))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport, legacy: Bool = false) {
        resizeLock.lock()
        if legacy, usesGeometryCallbacks { resizeLock.unlock(); return }
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        // Opt-in (`suppressesPixelOnlyResizes`): only a change in grid size
        // changes what a terminal app has to draw, so a host that repaints on
        // every dispatch can skip the sub-cell ones. The latest pixel metrics
        // are still recorded, so a later grid change carries them — but a host
        // that consumes pixels must leave this off, because without a further
        // grid change that update is never delivered.
        let gridChanged = lastResize.map {
            $0.columns != mergedResize.columns || $0.rows != mergedResize.rows
        } ?? true
        lastResize = mergedResize
        if suppressesPixelOnlyResizes, !gridChanged {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize sub-cell skipped cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels)"
            )

            return
        }

        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }

    /// Blocks until every `receive(_:)` call made so far has been fully parsed by the
    /// terminal engine's internal serial queue, including any resulting writeback (e.g.
    /// DECRPM/DA/OSC query responses the engine generates while parsing).
    ///
    /// `receive(_:)` only enqueues — it returns before parsing happens. A host that feeds
    /// buffered/replayed history and then flips some "replay done" flag on its own signal
    /// (rather than on this call returning) can observe writeback for that history arrive
    /// late, after the flag already says replay is over.
    ///
    /// Safe on the main thread: parsing fills ghostty's app mailbox, which only the main
    /// thread drains, so a main-thread caller ticks the app while it waits.
    public func waitForPendingOutput() {
        surfaceAccess.waitForPendingOutput()
    }

    private static func writeToSurface(_ surface: ghostty_surface_t, _ data: Data) {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let duration = ProcessInfo.processInfo.systemUptime - start
            if duration >= slowSurfaceWriteThreshold {
                TerminalDebugLog.log(
                    .output,
                    "surface write slow bytes=\(data.count) duration=\(String(format: "%.3f", duration))s"
                )
            }
        }

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    private static func reportProcessExit(
        _ surface: ghostty_surface_t,
        _ exitCode: UInt32,
        _ runtimeMilliseconds: UInt64
    ) {
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    private static func tickApp(_ surface: ghostty_surface_t) {
        ghostty_app_tick(ghostty_surface_app(surface))
    }
}
