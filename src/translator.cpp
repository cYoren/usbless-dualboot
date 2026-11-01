#include "translator.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>

Translator::Translator(QString languageFile, QObject *parent) : QTranslator(parent), m_file(languageFile) {
    if (m_file.isEmpty()) m_file = QDir::homePath() + "/.config/omarchy/language";
    connect(&m_watcher,&QFileSystemWatcher::fileChanged,this,[this] { reload(); });
    connect(&m_watcher,&QFileSystemWatcher::directoryChanged,this,[this] { reload(); });
    reload();
}
QString Translator::translate(const char *, const char *source, const char *, int) const {
    return m_strings.value(QString::fromUtf8(source));
}
void Translator::reload() {
    const auto paths = m_watcher.files() + m_watcher.directories();
    if (!paths.isEmpty()) m_watcher.removePaths(paths);
    if (QFileInfo::exists(m_file)) m_watcher.addPath(m_file);
    if (QFileInfo::exists(QFileInfo(m_file).absolutePath())) m_watcher.addPath(QFileInfo(m_file).absolutePath());
    QFile file(m_file);
    auto language = QLocale::system().name().replace('_','-');
    if (file.open(QIODevice::ReadOnly)) language = QString::fromUtf8(file.readLine()).trimmed();
    if (language.isEmpty()) language = "en";
    if (language == m_language) return;
    m_language = language; m_strings.clear();
    for (const auto &code : QStringList{language.section('-',0,0),language}) {
        QFile catalog(":/i18n/" + code + ".json");
        if (!catalog.open(QIODevice::ReadOnly)) continue;
        const auto object = QJsonDocument::fromJson(catalog.readAll()).object();
        for (auto it = object.begin(); it != object.end(); ++it) if (it.value().isString()) m_strings.insert(it.key(),it.value().toString());
    }
    const QLocale locale(language);
    QLocale::setDefault(locale); QGuiApplication::setLayoutDirection(locale.textDirection());
    emit changed();
}
