//
//  RadioRegionUITests.swift
//  Замок достижимости контролов радиоэкрана (полевое 13.08: секция
//  «Устройство» на месте, а тап по «Страна и частоты» не делал ничего).
//  Presence секции стережёт SettingsManifestTests; ЖИВОСТЬ тапа юнитом
//  не проверить — только реальный жест по реальной навигации.
//
//  Фаза .yielded (рабочая) инжектится launch-аргументом
//  --radio-fake-yielded: в симуляторе нет Bluetooth, а регресс жил
//  именно в рабочей фазе.
//

import XCTest

final class RadioRegionUITests: XCTestCase {

    @MainActor
    func testRegionLinkOpensRegionScreenInYielded() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--radio-fake-yielded"]
        app.launch()

        app.buttons["Настройки"].firstMatch.tap()
        let radioRow = app.staticTexts["Радиоустройства (LoRa)"].firstMatch
        XCTAssertTrue(radioRow.waitForExistence(timeout: 10),
                      "строка «Радиоустройства (LoRa)» не найдена в Настройках")
        radioRow.tap()

        // рабочая фаза: секция «Устройство» с контролом региона.
        // Поиск по label: секционный accessibilityIdentifier("radio.facts")
        // затирает детские id (проверено по иерархии падения 13.08)
        let regionLink = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Страна и частоты"))
            .firstMatch
        XCTAssertTrue(regionLink.waitForExistence(timeout: 10),
                      "контрол «Страна и частоты» не найден в .yielded — "
                      + "регресс достижимости (полевое 13.08)")
        regionLink.tap()

        // тап ОБЯЗАН привести на экран смены региона
        let title = app.navigationBars["Страна и частоты"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "тап по «Страна и частоты» не открыл экран смены "
                      + "региона — мёртвый контрол (полевое 13.08)")
    }
}
