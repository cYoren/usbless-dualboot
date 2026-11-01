#include "backend.h"
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QUuid>
#include <functional>

Backend::Backend(QString engine, QString stateDirectory, bool demo, QObject *parent)
    : QObject(parent), m_engine(std::move(engine)), m_state(std::move(stateDirectory)), m_demo(demo) {
    if (demo) {
        m_system = {{"uefi", "yes"}, {"root_fstype", "btrfs"}, {"encryption", "luks"},
                    {"secure_boot", "disabled"}, {"bootloader", "Limine"}, {"disk_name", "Internal SSD"}, {"disk_size", "1 TB"}};
        m_checks = {QVariantMap{{"status","ok"},{"message",tr("UEFI firmware is ready.")}},
                    QVariantMap{{"status","ok"},{"message",tr("Your existing Linux installation is detected.")}},
                    QVariantMap{{"status","ok"},{"message",tr("The power adapter is connected.")}},
                    QVariantMap{{"status","warning"},{"message",tr("Keep a separate backup before changing partitions.")}}};
        m_saved = {{"state","not_planned"}};
        m_iso = "/home/demo/Downloads/Windows11.iso"; m_size = "600G";
        m_notice = tr("Preview uses sample data. Disk actions are disabled.");
        return;
    }
    QDir().mkpath(m_state);
    QFile::setPermissions(m_state, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    m_watcher.addPath(m_state);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { readView(); });
    readView();
    QTimer::singleShot(0, this, &Backend::refresh);
}

void Backend::setIsoPath(const QString &value) { if (m_iso != value) { m_iso = value; emit changed(); } }
void Backend::setChecksum(const QString &value) { if (m_checksum != value) { m_checksum = value.trimmed(); emit changed(); } }
void Backend::setLinuxSize(const QString &value) { if (m_size != value) { m_size = value.trimmed(); emit changed(); } }
void Backend::setDirection(const QString &value) {
    if ((value == "windows" || value == "linux") && m_direction != value) { m_direction = value; emit changed(); }
}

void Backend::readView() {
    QFile file(m_state + "/view.json");
    if (!file.open(QIODevice::ReadOnly)) return;
    const auto bytes = file.readAll();
    if (bytes == m_viewBytes) return;
    const auto doc = QJsonDocument::fromJson(bytes);
    if (!doc.isObject() || !doc.object().value("status").isObject()) return;
    m_viewBytes = bytes;
    const auto view = doc.object();
    m_saved = view.value("status").toObject().toVariantMap();
    if (m_saved.value("direction") == "add-linux") m_direction = "linux";
    else if (m_saved.value("direction") == "add-windows") m_direction = "windows";
    if (m_saved.contains("iso")) m_iso = m_saved.value("iso").toString();
    if (m_saved.contains("linux_new_size")) m_size = m_saved.value("linux_new_size").toString();
    if (m_saved.contains("publisher_sha256")) m_checksum = m_saved.value("publisher_sha256").toString();
    m_checks.clear();
    for (const auto &value : view.value("doctor").toObject().value("checks").toArray()) {
        auto check = value.toObject().toVariantMap();
        const auto id = check.value("id").toString(), status = check.value("status").toString();
        QString message;
        if (id == "uefi") message = status == "ok" ? tr("UEFI firmware is ready.") : tr("Start Linux in UEFI mode before continuing.");
        else if (id == "architecture") message = status == "ok" ? tr("Your processor is supported.") : tr("This installer needs an x86-64 processor.");
        else if (id == "power") message = status == "ok" ? tr("The power adapter is connected.") : tr("Connect the power adapter before continuing.");
        else if (id == "tools") message = status == "ok" ? tr("Core installation tools are available.") : tr("Some required tools are missing. Open details for the list.");
        else if (id == "disk") message = status == "ok" ? tr("The disk matches the saved plan.") : tr("The disk no longer matches the plan. Stop and inspect it.");
        else if (id == "iso") message = status == "ok" ? tr("The ISO matches the saved fingerprint.") : tr("The ISO is missing or changed. Review it before continuing.");
        else if (id == "plan") message = tr("Create a plan before changing your drive.");
        else if (id == "authenticity") message = tr("Verify the ISO with a checksum from its publisher.");
        else if (id == "windows_encryption") message = tr("Keep the BitLocker recovery key before changing boot settings.");
        else if (id == "interrupted") message = tr("An earlier action was interrupted. Inspect recovery information before retrying.");
        else if (id == "filesystem") message = tr("Automatic shrinking needs Btrfs. This filesystem needs an offline procedure.");
        else if (id == "linux_boot") message = tr("The Linux beta needs Secure Boot off and a compatible ISO. It runs from your current Linux system.");
        if (!message.isEmpty()) check.insert("message",message);
        m_checks << check;
    }
    if (view.value("exit_code").toInt() != 0) m_error = view.value("action") == "doctor" ? tr("Some checks need attention before you continue.") : tr("The action stopped. Open the details or read the terminal before continuing.");
    else m_error.clear();
    QFile log(m_state + "/action.log");
    if (log.open(QIODevice::ReadOnly)) m_log = QString::fromUtf8(log.readAll()).right(48000);
    QFile plan(m_state + "/plan.log");
    if (plan.open(QIODevice::ReadOnly)) m_plan = QString::fromUtf8(plan.readAll()).right(48000);
    m_busy = false;
    emit changed();
}

void Backend::runReadOnly(const QStringList &args, const QString &kind) {
    if (m_demo || m_busy) return;
    if (!QFileInfo::exists(m_engine)) { m_error = tr("The command-line engine was not found. Build or install the complete project."); emit changed(); return; }
    m_busy = true; m_error.clear(); emit changed();
    auto *process = new QProcess(this);
    auto *timeout = new QTimer(process);
    timeout->setSingleShot(true); timeout->setInterval(kind == "verify" ? 600000 : 30000);
    connect(timeout, &QTimer::timeout, process, &QProcess::kill);
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) { m_busy = false; m_error = tr("Could not start the command-line engine."); emit changed(); process->deleteLater(); }
    });
    connect(process, &QProcess::finished, this, [this, process, kind](int code, QProcess::ExitStatus exit) {
        const auto bytes = process->readAllStandardOutput();
        const auto object = QJsonDocument::fromJson(bytes).object();
        if (code != 0 || exit != QProcess::NormalExit || object.isEmpty()) {
            m_error = QString::fromUtf8(process->readAllStandardError()).trimmed();
            if (m_error.isEmpty()) m_error = tr("The check could not finish. Review the details and try again.");
        } else if (kind == "probe") {
            m_system = object.toVariantMap();
            const auto disks = object.value("lsblk").toObject().value("blockdevices").toArray();
            const std::function<bool(const QJsonObject &)> holdsRoot = [&holdsRoot](const QJsonObject &disk) {
                for (const auto &mount : disk.value("mountpoints").toArray()) if (mount.toString() == "/") return true;
                for (const auto &child : disk.value("children").toArray()) if (holdsRoot(child.toObject())) return true;
                return false;
            };
            for (const auto &value : disks) {
                const auto disk = value.toObject();
                if (disk.value("type") == "disk" && holdsRoot(disk)) {
                    m_system.insert("disk_name", disk.value("name").toString());
                    const double capacity = disk.value("size").toDouble();
                    m_system.insert("disk_size", QLocale().toString(capacity / (1024.0 * 1024 * 1024),'f',0) + " GiB");
                    QVariantList segments;
                    double allocated = 0;
                    for (const auto &child : disk.value("children").toArray()) {
                        const auto part = child.toObject();
                        const double size = part.value("size").toDouble();
                        allocated += size;
                        segments << QVariantMap{{"ratio",capacity > 0 ? size / capacity : 0},{"color",holdsRoot(part) ? "#89b3c9" : "#d9c68f"}};
                    }
                    if (capacity > allocated + 16 * 1024 * 1024) segments << QVariantMap{{"ratio",(capacity - allocated)/capacity},{"color","#344955"}};
                    m_system.insert("segments", segments); break;
                }
            }
            if (m_checks.isEmpty()) {
                m_checks = {QVariantMap{{"status", m_system.value("uefi") == "yes" ? "ok" : "blocked"}, {"message",tr("UEFI firmware check")}},
                            QVariantMap{{"status","warning"},{"message",tr("Create a plan to check disk permissions, free space and installer readiness.")}}};
            }
        } else if (kind == "verify") {
            m_notice = object.value("result") == "verified" ? tr("The ISO matches the publisher checksum.")
                                                          : tr("Fingerprint calculated. A publisher checksum is needed to verify authenticity.");
            m_log = QString::fromUtf8(bytes);
        }
        m_busy = false; emit changed(); process->deleteLater();
    });
    process->start(m_engine, args); timeout->start();
}

void Backend::refresh() { if (m_demo) return; readView(); runReadOnly({"probe", "--json"}, "probe"); }
void Backend::retranslate() {
    if (m_demo) {
        m_checks = {QVariantMap{{"status","ok"},{"message",tr("UEFI firmware is ready.")}},
                    QVariantMap{{"status","ok"},{"message",tr("Your existing Linux installation is detected.")}},
                    QVariantMap{{"status","ok"},{"message",tr("The power adapter is connected.")}},
                    QVariantMap{{"status","warning"},{"message",tr("Keep a separate backup before changing partitions.")}}};
        m_notice = tr("Preview uses sample data. Disk actions are disabled."); emit changed();
    } else {
        m_viewBytes.clear(); readView();
        if (m_viewBytes.isEmpty()) refresh();
    }
}
void Backend::verifyIso() {
    if (!QFileInfo(m_iso).isFile()) { m_error = tr("Choose an existing ISO file first."); emit changed(); return; }
    QStringList args{"verify","--iso",m_iso,"--json"};
    if (!m_checksum.isEmpty()) args << "--sha256" << m_checksum;
    runReadOnly(args, "verify");
}

QStringList Backend::terminalArguments(const QString &terminal, const QString &runner, const QString &engine,
                                       const QString &state, const QString &action, const QStringList &parameters) {
    QStringList args;
    if (terminal == "kitty") args << "--hold";
    else if (terminal == "ghostty") args << "--wait-after-command" << "-e";
    else if (terminal == "foot") args << "--hold";
    else if (terminal == "alacritty") args << "--hold" << "-e";
    else args << "-hold" << "-e";
    return args + QStringList{"bash",runner,engine,state,action} + parameters;
}

void Backend::launch(const QString &action) {
    if (m_busy) return;
    if (m_demo) { m_error = tr("Preview mode cannot change disks or firmware."); emit changed(); return; }
    const QStringList allowed{"plan","shrink","stage","boot-installer","restore","cancel","windows","doctor"};
    if (!allowed.contains(action)) { m_error = tr("Unknown action."); emit changed(); return; }
    const auto state = m_saved.value("state","not_planned").toString();
    const bool matches = action == "doctor" ||
        (action == "plan" && (state == "not_planned" || state == "planned")) ||
        (action == "shrink" && state == "planned") ||
        (action == "stage" && state == "shrunk") ||
        (action == "boot-installer" && (state == "staged" || state == "boot_scheduled")) ||
        (action == "cancel" && state == "interrupted") ||
        ((action == "restore" || action == "cancel") && (state == "staged" || state == "boot_scheduled" || state == "boot_restored")) ||
        (action == "windows" && state == "boot_restored");
    if (!matches) { m_error = tr("This action does not match saved progress. Refresh or recheck readiness first."); emit changed(); return; }
    QStringList parameters;
    if (action == "plan") {
        if (!QFileInfo(m_iso).isFile() || !QRegularExpression("^[0-9]{1,7}[KMGTP](iB|B)?$").match(m_size).hasMatch()) {
            m_error = tr("Choose an ISO and enter how much space Linux should keep."); emit changed(); return;
        }
        if (!m_checksum.isEmpty() && !QRegularExpression("^[0-9a-fA-F]{64}$").match(m_checksum).hasMatch()) {
            m_error = tr("The checksum must contain 64 hexadecimal characters."); emit changed(); return;
        }
        parameters = {m_direction,m_iso,m_size,m_checksum};
    }
    const auto runner = QFileInfo(m_engine).absolutePath() + "/ui-action";
    if (!QFileInfo::exists(runner)) { m_error = tr("The terminal helper is missing. Install the complete project."); emit changed(); return; }
    QString terminal;
    for (const auto &name : {"kitty","ghostty","foot","alacritty","xterm"}) {
        if (!QStandardPaths::findExecutable(name).isEmpty()) { terminal = name; break; }
    }
    if (terminal.isEmpty()) { m_error = tr("Install a supported terminal: kitty, ghostty, foot, alacritty or xterm."); emit changed(); return; }
    m_error.clear(); m_notice = tr("Continue in the terminal. Your password stays there."); m_busy = true; emit changed();
    if (!QProcess::startDetached(QStandardPaths::findExecutable(terminal),
        terminalArguments(terminal, runner, m_engine, m_state, action, parameters))) {
        m_busy = false; m_error = tr("Could not open the terminal."); emit changed();
    }
    QTimer::singleShot(5000,this,[this] {
        if (m_busy && !QFileInfo::exists(m_state + "/running")) {
            m_busy = false; readView(); emit changed();
        }
    });
}

void Backend::chooseIso() {
    if (m_demo) return;
    auto bus = QDBusConnection::sessionBus();
    const auto token = "usbless" + QUuid::createUuid().toString(QUuid::Id128);
    auto sender = bus.baseService().mid(1); sender.replace('.', '_');
    const auto path = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;
    bus.connect("org.freedesktop.portal.Desktop",path,"org.freedesktop.portal.Request","Response",this,SLOT(fileChosen(uint,QVariantMap)));
    QDBusInterface picker("org.freedesktop.portal.Desktop","/org/freedesktop/portal/desktop","org.freedesktop.portal.FileChooser",bus);
    auto *watcher = new QDBusPendingCallWatcher(picker.asyncCall("OpenFile",QString(),tr("Choose an installer ISO"),
        QVariantMap{{"handle_token",token},{"multiple",false}}),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher] {
        QDBusPendingReply<QDBusObjectPath> reply = *watcher;
        if (reply.isError()) { m_error = tr("The system file picker is unavailable. Paste the ISO path instead."); emit changed(); }
        watcher->deleteLater();
    });
}
void Backend::fileChosen(uint response, const QVariantMap &results) {
    if (response == 0) {
        const auto uris = results.value("uris").toStringList();
        if (!uris.isEmpty()) setIsoPath(QUrl(uris.first()).toLocalFile());
    }
}
void Backend::openRecovery() {
    QDesktopServices::openUrl(QUrl("https://github.com/cYoren/usbless-dualboot/blob/main/docs/RECOVERY.md"));
}
