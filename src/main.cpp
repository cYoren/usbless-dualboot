#include "backend.h"
#include "theme.h"
#include "translator.h"
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QTimer>

int main(int argc, char **argv) {
    bool screenshot = false;
    for (int i = 1; i < argc; ++i) if (QString::fromLocal8Bit(argv[i]) == "--screenshot") screenshot = true;
    if (screenshot) { qputenv("QT_QPA_PLATFORM","offscreen"); qputenv("QT_QUICK_BACKEND","software"); }
    QGuiApplication app(argc,argv);
    app.setApplicationName("usbless"); app.setOrganizationName("usbless-dualboot"); app.setApplicationVersion("0.2.0");
    app.setDesktopFileName("usbless"); app.setWindowIcon(QIcon(":/raccoon.png"));
    const auto args = app.arguments();
    if (args.contains("--help")) {
        qInfo("USBless Dualboot graphical app\nUsage: usbless [--demo] [--screenshot PATH --width N --height N --page N]\nUse usbless-dualboot for headless disk operations."); return 0;
    }
    const bool demo = args.contains("--demo") || screenshot;
    const auto value = [&args](const QString &flag, const QString &fallback) {
        const auto index = args.indexOf(flag); return index >= 0 && index + 1 < args.size() ? args[index + 1] : fallback;
    };
    auto enginePath = qEnvironmentVariable("USBDB_ENGINE");
    if (enginePath.isEmpty()) {
        enginePath = QDir(QCoreApplication::applicationDirPath()).absoluteFilePath("../bin/usbless-dualboot");
        if (!QFileInfo::exists(enginePath)) enginePath = "/usr/lib/usbless-dualboot/bin/usbless-dualboot";
    }
    Theme theme({},demo);
    Translator translator(value("--language-file",QString()));
    app.installTranslator(&translator);
    const auto resolvedEngine = QFileInfo(enginePath).canonicalFilePath();
    Backend backend(resolvedEngine.isEmpty() ? QFileInfo(enginePath).absoluteFilePath() : resolvedEngine,QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation),demo);
    QQmlApplicationEngine engine;
    QObject::connect(&translator,&Translator::changed,&engine,&QQmlApplicationEngine::retranslate);
    QObject::connect(&translator,&Translator::changed,&backend,&Backend::retranslate);
    engine.rootContext()->setContextProperty("backend",&backend);
    engine.rootContext()->setContextProperty("theme",&theme);
    engine.rootContext()->setContextProperty("translator",&translator);
    engine.rootContext()->setContextProperty("initialWidth",value("--width","1140").toInt());
    engine.rootContext()->setContextProperty("initialHeight",value("--height","820").toInt());
    engine.rootContext()->setContextProperty("initialPage",value("--page","0").toInt());
    QQuickStyle::setStyle("Material");
    engine.load(QUrl("qrc:/Main.qml"));
    if (engine.rootObjects().isEmpty()) return 1;
    if (screenshot) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        const auto path = value("--screenshot",QString());
        QTimer::singleShot(1000,&app,[window,path,&app] {
            const auto image = window->grabWindow();
            if (image.isNull() || !image.save(path)) app.exit(1); else app.exit(0);
        });
    }
    return app.exec();
}
