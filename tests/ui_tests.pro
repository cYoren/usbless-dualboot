QT += core gui quick quickcontrols2 dbus testlib
CONFIG += c++17 testcase
TARGET = ui-tests
SOURCES += ui_tests.cpp ../src/backend.cpp ../src/theme.cpp ../src/translator.cpp
HEADERS += ../src/backend.h ../src/theme.h ../src/translator.h
INCLUDEPATH += ../src
RESOURCES += ../src/resources.qrc
