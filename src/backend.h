#pragma once
#include <QFileSystemWatcher>
#include <QObject>
#include <QProcess>
#include <QVariantMap>

class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool demo READ demo CONSTANT)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString notice READ notice NOTIFY changed)
    Q_PROPERTY(QVariantMap system READ system NOTIFY changed)
    Q_PROPERTY(QVariantMap saved READ saved NOTIFY changed)
    Q_PROPERTY(QVariantList checks READ checks NOTIFY changed)
    Q_PROPERTY(QString logText READ logText NOTIFY changed)
    Q_PROPERTY(QString planText READ planText NOTIFY changed)
    Q_PROPERTY(QString isoPath READ isoPath WRITE setIsoPath NOTIFY changed)
    Q_PROPERTY(QString checksum READ checksum WRITE setChecksum NOTIFY changed)
    Q_PROPERTY(QString linuxSize READ linuxSize WRITE setLinuxSize NOTIFY changed)
    Q_PROPERTY(QString direction READ direction WRITE setDirection NOTIFY changed)
    Q_PROPERTY(QString stateDirectory READ stateDirectory CONSTANT)
public:
    explicit Backend(QString engine, QString stateDirectory, bool demo = false, QObject *parent = nullptr);
    bool busy() const { return m_busy; }
    bool demo() const { return m_demo; }
    QString error() const { return m_error; }
    QString notice() const { return m_notice; }
    QVariantMap system() const { return m_system; }
    QVariantMap saved() const { return m_saved; }
    QVariantList checks() const { return m_checks; }
    QString logText() const { return m_log; }
    QString planText() const { return m_plan; }
    QString isoPath() const { return m_iso; }
    QString checksum() const { return m_checksum; }
    QString linuxSize() const { return m_size; }
    QString direction() const { return m_direction; }
    QString stateDirectory() const { return m_state; }
    void setIsoPath(const QString &value);
    void setChecksum(const QString &value);
    void setLinuxSize(const QString &value);
    void setDirection(const QString &value);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void retranslate();
    Q_INVOKABLE void chooseIso();
    Q_INVOKABLE void verifyIso();
    Q_INVOKABLE void launch(const QString &action);
    Q_INVOKABLE void openRecovery();
    static QStringList terminalArguments(const QString &terminal, const QString &runner,
                                         const QString &engine, const QString &state,
                                         const QString &action, const QStringList &parameters);
signals:
    void changed();
private slots:
    void fileChosen(uint response, const QVariantMap &results);
private:
    void readView();
    void runReadOnly(const QStringList &args, const QString &kind);
    QString m_engine, m_state, m_error, m_notice, m_log, m_plan, m_iso, m_checksum, m_size, m_direction = "windows";
    QVariantMap m_system, m_saved;
    QVariantList m_checks;
    QFileSystemWatcher m_watcher;
    QByteArray m_viewBytes;
    bool m_busy = false, m_demo = false;
};
