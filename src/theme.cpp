#include "theme.h"
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <cmath>

Theme::Theme(QString directory, bool preview, QObject *parent) : QObject(parent), m_directory(directory) {
    if (preview) return;
    if (m_directory.isEmpty()) m_directory = QDir::homePath() + "/.local/state/omarchy/current";
    connect(&m_watcher,&QFileSystemWatcher::directoryChanged,this,[this] { reload(); });
    connect(&m_watcher,&QFileSystemWatcher::fileChanged,this,[this] { reload(); });
    connect(&m_process,&QProcess::finished,this,[this](int code) {
        const auto value = QJsonDocument::fromJson(m_process.readAllStandardOutput()).object().value("int");
        if (code == 0 && value.isDouble() && value.toInt() >= 0 && value.toInt() != m_radius) {
            m_radius = value.toInt(); emit changed();
        }
    });
    if (!qEnvironmentVariableIsEmpty("HYPRLAND_INSTANCE_SIGNATURE") && !QStandardPaths::findExecutable("hyprctl").isEmpty()) {
        connect(&m_poll,&QTimer::timeout,this,[this] {
            if (m_process.state() == QProcess::NotRunning) {
                m_process.start("hyprctl",{"-j","getoption","decoration:rounding"});
                QTimer::singleShot(1000,&m_process,[this] { if (m_process.state() != QProcess::NotRunning) m_process.kill(); });
            }
        });
        m_poll.start(3000);
    }
    reload();
}
Theme::~Theme() {
    if (m_process.state() != QProcess::NotRunning) { m_process.kill(); m_process.waitForFinished(1000); }
}
void Theme::reload() {
    const auto paths = m_watcher.files() + m_watcher.directories();
    if (!paths.isEmpty()) m_watcher.removePaths(paths);
    QString ancestor = m_directory;
    while (!QFileInfo::exists(ancestor) && ancestor != "/") ancestor = QFileInfo(ancestor).absolutePath();
    QStringList candidates{ancestor,QFileInfo(ancestor).absolutePath(),m_directory,m_directory + "/theme",m_directory + "/theme/colors.toml"};
    candidates.removeDuplicates();
    for (const auto &path : candidates) if (QFileInfo::exists(path)) m_watcher.addPath(path);
    QFile file(m_directory + "/theme/colors.toml");
    QString color = "#FFD60A";
    if (file.open(QIODevice::ReadOnly)) {
        const auto match = QRegularExpression(R"(^\s*accent\s*=\s*["'](#[0-9a-fA-F]{6})["'])",QRegularExpression::MultilineOption).match(QString::fromUtf8(file.readAll()));
        if (match.hasMatch()) color = match.captured(1);
    }
    if (color != m_accent) { m_accent = color; emit changed(); }
}
QString Theme::foreground() const {
    const QColor color(m_accent);
    auto linear = [](double value) { return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055,2.4); };
    const double light = 0.2126 * linear(color.redF()) + 0.7152 * linear(color.greenF()) + 0.0722 * linear(color.blueF());
    return light > 0.179 ? "#122029" : "#ffffff";
}
