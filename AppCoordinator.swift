import SwiftUI

@Observable
final class AppCoordinator {
    enum Destination {
        case home
        case review
    }

    var destination: Destination = .home

    func startReview() { destination = .review }
    func goHome() { destination = .home }
}
