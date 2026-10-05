import MeterApp
import SwiftUI

/// Notices, the hero, and the card list.
struct AccountsView: View {
    let accounts: AccountsModel
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ForEach(accounts.notices) { notice in
                NoticeBanner(notice)
            }
            HeroView(hero: accounts.hero)
            CardList(accounts: accounts, model: model)
        }
    }
}
