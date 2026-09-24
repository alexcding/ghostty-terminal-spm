//
//  TerminalViewState+Mutation.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import SwiftUI

public extension TerminalViewState {
    // SwiftUI lifecycle callbacks can run inside Update.dispatchActions. Keep
    // the public imperative adopt API synchronous, but defer view-driven work.
    // Only the latest request from the still-attached view/controller may apply.
    internal func requestColorScheme(_ colorScheme: ColorScheme) {
        let request = UUID()
        colorSchemeRequest = request
        terminalRunOnMainNextTurn { [weak self, weak view = attachedView, weak controller] in
            guard let self, colorSchemeRequest == request, self.controller === controller,
                  let view, attachedView === view, view.window != nil else { return }
            adopt(colorScheme: colorScheme)
        }
    }

    func adopt(colorScheme: ColorScheme) {
        adopt(terminalColorScheme: TerminalColorScheme(colorScheme))
    }

    func adopt(terminalColorScheme colorScheme: TerminalColorScheme) {
        guard colorScheme != controller.effectiveColorScheme else { return }
        controller.setColorScheme(colorScheme) {
            self.objectWillChange.send()
        }
    }

    @discardableResult
    func setTheme(_ theme: TerminalTheme) -> Bool {
        return controller.setTheme(theme) {
            self.objectWillChange.send()
        }
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        return controller.setTerminalConfiguration(terminalConfiguration) {
            self.objectWillChange.send()
        }
    }
}
