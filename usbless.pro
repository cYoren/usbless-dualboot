QT += core gui quick quickcontrols2 dbus
CONFIG += c++17
TARGET = usbless
TEMPLATE = app
SOURCES += src/main.cpp src/backend.cpp src/theme.cpp src/translator.cpp
HEADERS += src/backend.h src/theme.h src/translator.h
RESOURCES += src/resources.qrc
QMAKE_CXXFLAGS += -Wall -Wextra
