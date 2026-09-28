//
//  KeyboardDismissUITests.swift
//  Замок блока 6 (полевое 09.08): клавиатуру нельзя было убрать, не
//  выходя из чата. Спека владельца: тап по ленте / свайп вниз прячут
//  клавиатуру. Живой жест проверяется только UI-тестом — юнит не
//  видит ни клавиатуры, ни жестов.
//

import XCTest

final class KeyboardDismissUITests: XCTestCase {

    @MainActor
    func testTapOnFeedDismissesKeyboard() throws {
        let app = XCUIApplication()
        // демо-чат убран из живого UI (полевой пакет 13.08); замку
        // нужен чат без контактов — дверь только для тестов (DEBUG)
        app.launchArguments += ["--demo-chat"]
        app.launch()

        let demo = app.staticTexts["Как это выглядит"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10),
                      "список чатов не открылся")
        demo.tap()

        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10),
                      "композер чата не найден")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "клавиатура не открылась по тапу в поле")

        // тап по телу ленты (выше композера) обязан спрятать клавиатуру
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .tap()
        let gone = NSPredicate(format: "exists == false")
        let dismissed = XCTNSPredicateExpectation(
            predicate: gone, object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [dismissed], timeout: 5),
                       .completed,
                       "клавиатура обязана уйти по тапу по ленте — "
                       + "выход из чата ради этого запрещён (спека 10.08)")
    }
}
