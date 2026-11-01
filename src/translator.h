#pragma once
#include <QFileSystemWatcher>
#include <QHash>
#include <QLocale>
#include <QTranslator>

class Translator : public QTranslator {
    Q_OBJECT
    Q_PROPERTY(QString language READ language NOTIFY changed)
    Q_PROPERTY(bool rightToLeft READ rightToLeft NOTIFY changed)
public:
    explicit Translator(QString languageFile = {}, QObject *parent = nullptr);
    QString language() const { return m_language; }
    bool rightToLeft() const { return QLocale(m_language).textDirection() == Qt::RightToLeft; }
    bool isEmpty() const override { return m_strings.isEmpty(); }
    QString translate(const char *, const char *source, const char * = nullptr, int = -1) const override;
signals:
    void changed();
private:
    void reload();
    QString m_file, m_language;
    QHash<QString,QString> m_strings;
    QFileSystemWatcher m_watcher;
};
