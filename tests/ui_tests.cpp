#include "backend.h"
#include "theme.h"
#include "translator.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

class UiTests : public QObject {
    Q_OBJECT
private:
    static bool write(const QString &path, const QByteArray &content) {
        QFile file(path); return file.open(QIODevice::WriteOnly) && file.write(content) == content.size();
    }
private slots:
    void initTestCase() { QQuickStyle::setStyle("Material"); }
    void previewCannotLaunchDiskActions() {
        QTemporaryDir dir;
        Backend backend("/nonexistent",dir.path(),true);
        for (const auto &action : {"plan","shrink","stage","restore","windows"}) {
            backend.launch(action);
            QVERIFY(!backend.busy()); QVERIFY(backend.error().contains("Preview"));
        }
        QVERIFY(QDir(dir.path()).entryList(QDir::Files).isEmpty());
    }
    void terminalArgumentsKeepPathsLiteral() {
        const QString hostile = "/tmp/iso with spaces;$(touch SHOULD_NOT_EXIST).iso";
        const auto args = Backend::terminalArguments("kitty","/repo/bin/ui-action","/repo/bin/usbless-dualboot","/state","plan",{"windows",hostile,"600G",""});
        QCOMPARE(args[0],QString("--hold"));
        QCOMPARE(args[7],hostile);
        QVERIFY(!args.contains("-c"));
        QCOMPARE(args.last(),QString());
    }
    void invalidPlanNeverOpensTerminal() {
        QTemporaryDir dir;
        Backend backend("/missing",dir.path());
        backend.setIsoPath(dir.path() + "/missing.iso"); backend.setLinuxSize("600G");
        backend.launch("plan");
        QVERIFY(!backend.busy()); QVERIFY(backend.error().contains("Choose an ISO"));
    }
    void phaseGuardRejectsOutOfOrderActions() {
        QTemporaryDir dir;
        Backend backend("/missing",dir.path());
        for (const auto &action : {"stage","shrink","restore","windows","boot-installer"}) {
            backend.launch(action);
            QVERIFY(!backend.busy()); QVERIFY(backend.error().contains("saved progress"));
        }
    }
    void probeSelectsTheDiskThatContainsRoot() {
        QTemporaryDir dir;
        const auto engine = QFINDTESTDATA("fixtures/ui-engine");
        QVERIFY(!engine.isEmpty());
        Backend backend(engine,dir.path());
        QTRY_COMPARE(backend.system().value("disk_name").toString(),QString("correct-root-disk"));
        const auto segments = backend.system().value("segments").toList();
        QCOMPARE(segments.size(),3);
        QCOMPARE(segments[1].toMap().value("color").toString(),QString("#89b3c9"));
        QVERIFY(!backend.busy());
    }
    void viewRestoresSavedProgress() {
        QTemporaryDir dir;
        QVERIFY(write(dir.filePath("view.json"),R"({"status":{"state":"interrupted","last_backup":"/private/backup"},"doctor":{"checks":[{"status":"blocked","message":"Inspect disk"}]},"exit_code":1})"));
        Backend backend("/missing",dir.path());
        QCOMPARE(backend.saved().value("state").toString(),QString("interrupted"));
        QCOMPARE(backend.checks().size(),1); QVERIFY(!backend.error().isEmpty());
    }
    void partialViewDoesNotCreateSuccessState() {
        QTemporaryDir dir;
        QVERIFY(write(dir.filePath("view.json"),"{broken"));
        Backend backend("/missing",dir.path());
        QVERIFY(backend.saved().isEmpty());
    }
    void themeFallsBackAndFollowsChanges() {
        QTemporaryDir dir;
        QDir(dir.path()).mkdir("theme");
        Theme theme(dir.path()); QCOMPARE(theme.accent(),QString("#FFD60A"));
        QVERIFY(write(dir.filePath("theme/colors.toml"),"accent = '#123456'\n"));
        QTRY_COMPARE(theme.accent(),QString("#123456")); QCOMPARE(theme.foreground(),QString("#ffffff"));
    }
    void portugueseAndEnglishFallback() {
        QTemporaryDir dir;
        QVERIFY(write(dir.filePath("language"),"pt-BR\n"));
        Translator translator(dir.filePath("language"));
        QCOMPARE(translator.translate("Main","Choose an installer"),QString("Escolha o instalador"));
        QVERIFY(translator.translate("Main","Not in the catalog").isNull());
        QVERIFY(write(dir.filePath("language"),"en\n"));
        QTRY_COMPARE(translator.language(),QString("en"));
        QVERIFY(translator.translate("Main","Choose an installer").isNull());
    }
    void realQmlLoadsAndPrimaryButtonNavigates() {
        QTemporaryDir dir;
        Backend backend("/missing",dir.path(),true);
        Theme theme({},true);
        Translator translator(dir.filePath("language"));
        QQmlApplicationEngine engine;
        QSignalSpy warnings(&engine,&QQmlEngine::warnings);
        engine.rootContext()->setContextProperty("backend",&backend);
        engine.rootContext()->setContextProperty("theme",&theme);
        engine.rootContext()->setContextProperty("translator",&translator);
        engine.rootContext()->setContextProperty("initialWidth",1140);
        engine.rootContext()->setContextProperty("initialHeight",820);
        engine.rootContext()->setContextProperty("initialPage",0);
        engine.load(QUrl("qrc:/Main.qml"));
        QCOMPARE(engine.rootObjects().size(),1);
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first()); QVERIFY(window);
        auto *button = window->findChild<QQuickItem *>("primaryButton"); QVERIFY(button);
        QTest::qWait(50);
        const auto point = button->mapToScene(QPointF(button->width()/2,button->height()/2)).toPoint();
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point);
        QCOMPARE(window->property("page").toInt(),1);
        QVERIFY(QMetaObject::invokeMethod(window,"advance")); QCOMPARE(window->property("page").toInt(),2);
        window->setProperty("page",3);
        QVERIFY(QMetaObject::invokeMethod(window,"advance"));
        auto *dialog = window->findChild<QObject *>("confirmationDialog"); QVERIFY(dialog);
        QVERIFY(dialog->property("visible").toBool());
        QVERIFY(!backend.busy());
        for (int page = 0; page < 5; ++page) {
            window->setProperty("page",page);
            window->setWidth(390); window->setHeight(844); QTest::qWait(20);
            QVERIFY(!window->grabWindow().isNull());
        }
        QCOMPARE(warnings.size(),0);
    }
};
QTEST_MAIN(UiTests)
#include "ui_tests.moc"
