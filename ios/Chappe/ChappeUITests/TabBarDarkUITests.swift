//
//  TabBarDarkUITests.swift
//  ChappeUITests
//
//  WP0 (бриф 02.08): светлая карта не должна перекрашивать таб-бар
//  других вкладок. Маршрут приёмки: карта светлая → Чаты → Софи →
//  Настройки → обратно на карту; скриншот на каждом шаге — «до/после»
//  чинится и проверяется одним и тем же тестом (вложения в xcresult).
//

import XCTest

final class TabBarDarkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabBarStaysDarkAfterLightMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-tab", "map", "--map-style-light"]
        app.launch()

        // тайлам нужно время; светлый стиль виден и без сети (фон стиля)
        sleep(6)
        snap(app, "01_карта_светлая")

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "таб-бар не найден")

        tabBar.buttons["Чаты"].tap()
        sleep(1)
        snap(app, "02_чаты_после_карты")

        tabBar.buttons["Софи"].tap()
        sleep(1)
        snap(app, "03_софи")

        tabBar.buttons["Настройки"].tap()
        sleep(1)
        snap(app, "04_настройки")

        tabBar.buttons["Карта"].tap()
        sleep(2)
        snap(app, "05_снова_карта")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
