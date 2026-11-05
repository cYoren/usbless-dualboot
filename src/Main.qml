pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: initialWidth
    height: initialHeight
    minimumWidth: 360
    minimumHeight: 640
    visible: true
    title: qsTr("USBless Dualboot")
    color: "#19262f"
    font.family: "Adwaita Sans"
    font.pixelSize: 15
    Material.theme: Material.Dark
    Material.accent: theme.accent
    Material.roundedScale: theme.radius
    property int page: Math.max(0, Math.min(4, initialPage))
    property bool wide: width >= 960
    property bool compact: width < 600
    property color ink: "#eff5f5"
    property color muted: "#a8bdc7"
    property color panel: "#22333f"
    property color line: "#3b4e5b"
    property color mint: "#a3d8bf"
    property string pendingAction: ""
    property string progress: backend.saved.state || "not_planned"
    property bool installerRemoved: progress === "installer_removed"
    property bool cleanupReady: Boolean(backend.cleanupPreview.carrier) && Number(backend.cleanupPreview.bytes) > 0
    property string cleanupIdentity: String(backend.cleanupPreview.disk || "") + "|" + String(backend.cleanupPreview.partuuid || "") + "|" + String(backend.cleanupPreview.bytes || "")
    property bool interfaceReady: false
    Component.onCompleted: window.interfaceReady = true
    onCleanupIdentityChanged: if (interfaceReady) bothBooted.checked = false
    property var steps: [qsTr("Check your PC"), qsTr("Choose an installer"), qsTr("Review the plan"), qsTr("Prepare installation"), qsTr("Finish up")]

    function advance() {
        if (page === 0) page = 1
        else if (page === 1) {
            if (backend.demo) page = 2
            else { backend.launch("plan"); page = 2 }
        } else if (page === 2) page = 3
        else if (page === 3) {
            if (progress === "boot_scheduled" || progress === "boot_restored" || installerRemoved) page = 4
            else {
                pendingAction = progress === "shrunk" ? "stage" : progress === "staged" ? "boot-installer" : "shrink"
                confirm.open()
            }
        } else { pendingAction = "restore"; confirm.open() }
    }
    function primaryText() {
        if (page === 0) return qsTr("Choose an installer")
        if (page === 1) return qsTr("Create my plan")
        if (page === 2) return qsTr("Prepare installation")
        if (page === 4) return cleanupReady && progress === "boot_restored" ? qsTr("Remove installer") : progress === "boot_restored" || installerRemoved ? qsTr("Refresh progress") : qsTr("Restore boot priority")
        if (progress === "shrunk") return qsTr("Build the installer")
        if (progress === "staged") return qsTr("Set the next boot")
        if (progress === "boot_scheduled" || progress === "boot_restored") return qsTr("Finish up")
        return qsTr("Make room for installation")
    }
    function progressMessage() {
        if (progress === "planned") return qsTr("Your plan is saved. Review it and connect power before making room.")
        if (progress === "shrunk") return qsTr("Space is ready. Restart Linux before building the installer so it can read the new partition sizes.")
        if (progress === "staged") return qsTr("The installer is ready. Set the next boot, then restart when you are ready.")
        if (progress === "boot_scheduled") return qsTr("The next restart will use the installer once. This does not mean the new system has been installed.")
        if (progress === "boot_restored") return qsTr("Your previous boot priority is restored. Check that both operating systems start.")
        if (installerRemoved) return qsTr("The installer is removed. Its space is available, and recovery backups are retained.")
        if (progress === "interrupted") return qsTr("An earlier action was interrupted. Inspect recovery information before retrying.")
        return qsTr("Create and review your plan before making room on the drive.")
    }

    component Copy: Label {
        color: window.muted
        wrapMode: Text.WordWrap
        lineHeight: 1.25
        Layout.fillWidth: true
        Accessible.role: Accessible.StaticText
    }
    component Heading: Label {
        color: window.ink
        font.pixelSize: 23
        font.weight: Font.DemiBold
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
    component QuietButton: Button {
        implicitHeight: 44
        topInset: 0
        bottomInset: 0
        font.weight: Font.Medium
        Accessible.name: text
        background: Rectangle {
            color: parent.down ? "#38505e" : parent.hovered ? "#304754" : "transparent"
            border.color: parent.activeFocus ? theme.accent : window.line
            border.width: parent.activeFocus ? 2 : 1
            radius: theme.radius
        }
        contentItem: Label { text: parent.text; color: window.ink; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font: parent.font }
    }
    component CheckRow: RowLayout {
        property string checkStatus: "ok"
        property string message: ""
        spacing: 12
        Layout.fillWidth: true
        Label { text: checkStatus === "ok" ? "✓" : checkStatus === "blocked" ? "!" : "○"; color: checkStatus === "ok" ? window.mint : checkStatus === "blocked" ? "#ffb7a4" : "#e2c68e"; font.pixelSize: 20; Layout.alignment: Qt.AlignTop; Layout.preferredWidth: 22 }
        Copy { text: parent.message; color: window.ink }
    }

    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: translator.rightToLeft
        LayoutMirroring.childrenInherit: true
        RowLayout {
            anchors.fill: parent
            spacing: 0
            Rectangle {
                visible: window.wide
                Layout.preferredWidth: 246
                Layout.fillHeight: true
                color: "#14212a"
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 28
                    spacing: 10
                    Label { text: qsTr("USBless"); color: window.ink; font.pixelSize: 27; font.weight: Font.Bold; Layout.topMargin: 8 }
                    Copy { text: qsTr("Two systems. One home."); font.pixelSize: 13; Layout.bottomMargin: 48 }
                    Repeater {
                        model: window.steps
                        delegate: Button {
                            required property int index
                            required property string modelData
                            text: modelData
                            Layout.fillWidth: true
                            implicitHeight: 58
                            onClicked: window.page = index
                            background: Rectangle { radius: theme.radius; color: window.page === parent.index ? "#2b3e4a" : "transparent"; border.color: parent.activeFocus ? theme.accent : "transparent" }
                            contentItem: RowLayout {
                                spacing: 12
                                Rectangle { width: 26; height: 26; radius: 13; color: window.page === index ? theme.accent : "transparent"; border.color: window.page === index ? theme.accent : window.line
                                    Label { anchors.centerIn: parent; text: index + 1; color: window.page === index ? theme.foreground : window.muted; font.pixelSize: 12; font.weight: Font.Bold }
                                }
                                Label { text: modelData; color: window.page === index ? window.ink : window.muted; font.pixelSize: 13; font.weight: window.page === index ? Font.DemiBold : Font.Normal; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Rectangle { height: 1; color: window.line; Layout.fillWidth: true }
                    Copy { text: qsTr("Your existing system stays yours."); font.pixelSize: 12; Layout.topMargin: 14 }
                    QuietButton { text: qsTr("Recovery guide"); flat: true; onClicked: backend.openRecovery(); Layout.fillWidth: true; Layout.topMargin: 10 }
                    Label { text: "v0.2.0"; color: window.muted; font.pixelSize: 11; Layout.topMargin: 6 }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 60
                    color: "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: window.compact ? 22 : 40; anchors.rightMargin: window.compact ? 22 : 40
                        Image { visible: window.compact; source: "qrc:/raccoon.png"; fillMode: Image.PreserveAspectFit; Layout.preferredWidth: 30; Layout.preferredHeight: 34; Accessible.name: qsTr("Raccoon holding an internal drive") }
                        Label { text: window.wide ? qsTr("Installation workspace") : qsTr("USBless Dualboot"); color: window.muted; font.pixelSize: 13 }
                        Item { Layout.fillWidth: true }
                        BusyIndicator { running: backend.busy; visible: running; implicitWidth: 24; implicitHeight: 24 }
                        Label { text: backend.demo ? qsTr("Preview") : qsTr("Linux edition"); color: window.mint; font.pixelSize: 12 }
                        ToolButton { text: "?"; Accessible.name: qsTr("Keyboard shortcuts"); onClicked: shortcuts.open() }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: window.line }
                RowLayout {
                    visible: !window.wide
                    Layout.fillWidth: true; Layout.margins: window.compact ? 16 : 28; spacing: 8
                    Repeater {
                        model: 5
                        delegate: Button {
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: 40
                            topInset: 0
                            bottomInset: 0
                            text: (index + 1).toString()
                            Accessible.name: window.steps[index]
                            onClicked: window.page = index
                            background: Rectangle { radius: theme.radius; color: window.page === index ? theme.accent : window.panel; border.color: parent.activeFocus ? window.ink : "transparent" }
                            contentItem: Label { text: parent.text; color: window.page === index ? theme.foreground : window.muted; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.weight: Font.DemiBold }
                        }
                    }
                }

                ScrollView {
                    id: scroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: availableWidth
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    ColumnLayout {
                        width: scroll.availableWidth
                        spacing: 24
                        Item { Layout.preferredHeight: window.compact ? 0 : 8 }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: window.compact ? 22 : 40
                            Layout.rightMargin: window.compact ? 22 : 40
                            spacing: 24

                            Rectangle {
                                visible: backend.error !== "" || backend.notice !== ""
                                Layout.fillWidth: true; implicitHeight: banner.implicitHeight + 24; radius: theme.radius
                                color: backend.error !== "" ? "#4b3030" : "#293d47"
                                Label { id: banner; anchors.fill: parent; anchors.margins: 12; color: backend.error !== "" ? "#ffcfbf" : window.muted; text: backend.error || backend.notice; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                            }

                            RowLayout {
                                Layout.fillWidth: true; spacing: 12
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 10
                                    Label { text: window.steps[window.page]; color: window.mint; font.pixelSize: 13; font.weight: Font.Medium }
                                    Label {
                                        Layout.fillWidth: true
                                        text: window.page === 0 ? qsTr("Make room for\nsomething new.") : window.page === 1 ? qsTr("Bring your installer.") : window.page === 2 ? qsTr("Know what will change.") : window.page === 3 ? qsTr("One careful step\nat a time.") : window.installerRemoved ? qsTr("Installer removed") : window.cleanupReady ? qsTr("Remove the installer") : qsTr("Welcome to both worlds.")
                                        color: window.ink; font.pixelSize: window.compact ? 31 : 40; font.weight: Font.DemiBold; lineHeight: 1.08; wrapMode: Text.WordWrap
                                    }
                                    Copy { text: window.page === 0 ? qsTr("Add Windows beside Linux using your internal drive. No USB stick needed.") : window.page === 1 ? qsTr("Use an official ISO. We will check it before preparing your drive.") : window.page === 2 ? qsTr("A plan changes no partitions. Review it before continuing.") : window.page === 3 ? qsTr("Progress is saved between restarts. Each disk change needs your confirmation.") : window.cleanupReady ? qsTr("Confirm that both systems start before freeing this space.") : qsTr("Keep both systems easy to reach, then check that each one boots."); font.pixelSize: 14 }
                                }
                                Image { visible: !window.compact && window.page === 0; source: "qrc:/raccoon.png"; fillMode: Image.PreserveAspectFit; Layout.preferredWidth: window.wide ? 174 : 150; Layout.preferredHeight: 184; Accessible.name: qsTr("Raccoon holding an internal drive") }
                            }

                            ColumnLayout {
                                visible: window.page === 0
                                Layout.fillWidth: true; spacing: 22
                                Rectangle {
                                    color: window.panel; radius: theme.radius; Layout.fillWidth: true; implicitHeight: diskContent.implicitHeight + 40
                                    ColumnLayout {
                                        id: diskContent; anchors.fill: parent; anchors.margins: 20; spacing: 14
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Label { text: qsTr("Your internal drive"); color: window.ink; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                            Label { text: backend.system.disk_size || qsTr("Checking…"); color: window.ink; font.weight: Font.DemiBold }
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true; height: 26; color: "#344955"; radius: Math.min(4,theme.radius); clip: true
                                            Row {
                                                anchors.fill: parent
                                                Repeater {
                                                    model: backend.demo ? [{ratio:0.025,color:"#d9c68f"},{ratio:0.975,color:"#89b3c9"}] : (backend.system.segments || [])
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: parent.width * modelData.ratio; height: parent.height; color: modelData.color
                                                    }
                                                }
                                            }
                                        }
                                        Copy { text: backend.demo ? qsTr("Sample layout: EFI and Linux. Your plan will calculate the space for the new system.") : qsTr("Detected storage is shown here. The plan checks the exact disk and partition boundaries."); font.pixelSize: 12 }
                                        RowLayout {
                                            Layout.fillWidth: true; spacing: 18
                                            Label { text: "●  " + qsTr("Linux"); color: "#89b3c9"; font.pixelSize: 12 }
                                            Label { text: "●  " + qsTr("EFI / other"); color: "#d9c68f"; font.pixelSize: 12 }
                                            Item { Layout.fillWidth: true }
                                        }
                                    }
                                }
                                Heading { text: qsTr("A quick look before we begin"); font.pixelSize: 18 }
                                Repeater {
                                    model: backend.checks
                                    delegate: CheckRow { required property var modelData; checkStatus: modelData.status; message: modelData.message }
                                }
                                QuietButton { text: qsTr("Refresh checks"); enabled: !backend.busy; onClicked: backend.refresh() }
                            }

                            ColumnLayout {
                                visible: window.page === 1
                                Layout.fillWidth: true; spacing: 16
                                Heading { text: qsTr("Which system are you adding?"); font.pixelSize: 18 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RadioButton { text: "Windows"; checked: backend.direction === "windows"; onClicked: backend.direction = "windows" }
                                    RadioButton { text: qsTr("Linux (beta)"); checked: backend.direction === "linux"; onClicked: backend.direction = "linux" }
                                }
                                Copy { visible: backend.direction === "linux"; text: qsTr("The Linux beta needs Secure Boot off and a compatible ISO. It runs from your current Linux system."); color: "#e2c68e"; font.pixelSize: 13 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    TextField { id: isoField; Layout.fillWidth: true; placeholderText: qsTr("Installer ISO path"); text: backend.isoPath; onTextEdited: backend.isoPath = text; selectByMouse: true; Accessible.name: placeholderText }
                                    QuietButton { text: qsTr("Browse"); onClicked: backend.chooseIso() }
                                }
                                TextField { Layout.fillWidth: true; placeholderText: qsTr("Publisher SHA-256 (recommended)"); text: backend.checksum; onTextEdited: backend.checksum = text; selectByMouse: true; Accessible.name: placeholderText }
                                Copy { text: qsTr("Copy the checksum from the OS publisher. Without it, we can detect changes to the file but cannot verify its origin."); font.pixelSize: 12 }
                                QuietButton { text: qsTr("Check this ISO"); enabled: !backend.busy && backend.isoPath !== ""; onClicked: backend.verifyIso() }
                                Rectangle { Layout.fillWidth: true; height: 1; color: window.line; Layout.topMargin: 12; Layout.bottomMargin: 4 }
                                TextField {
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Linux space to keep (GiB)")
                                    text: backend.linuxSize.replace(/G(iB|B)?$/, "")
                                    onTextEdited: backend.linuxSize = text === "" ? "" : text + "G"
                                    validator: IntValidator { bottom: 1; top: 1000000 }
                                    inputMethodHints: Qt.ImhDigitsOnly
                                    selectByMouse: true
                                    Accessible.name: placeholderText
                                }
                                Copy { text: qsTr("This is the final size of your existing Linux partition, not the amount to remove. The plan rejects a size that cannot fit."); font.pixelSize: 12 }
                            }

                            ColumnLayout {
                                visible: window.page === 2
                                Layout.fillWidth: true; spacing: 20
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: summary.implicitHeight + 40; color: window.panel; radius: theme.radius
                                    ColumnLayout {
                                        id: summary; anchors.fill: parent; anchors.margins: 20; spacing: 15
                                        Heading { text: qsTr("What stays"); font.pixelSize: 18 }
                                        CheckRow { message: qsTr("Your existing Linux installation and files") }
                                        CheckRow { message: qsTr("Your EFI partition and normal boot priority") }
                                        Heading { text: qsTr("What changes"); font.pixelSize: 18; Layout.topMargin: 8 }
                                        Copy { text: qsTr("Linux becomes smaller. The freed space holds the new OS and a temporary installer.") }
                                        Copy { text: backend.demo ? qsTr("Example: Linux keeps 600 GiB. The real plan calculates the exact remaining space.") : (backend.saved.disk ? qsTr("Planned disk: %1").arg(backend.saved.disk) : qsTr("Create a plan from the previous step to see exact sizes. No disk changes have been made.")); color: window.mint; font.pixelSize: 13 }
                                    }
                                }
                                Heading { text: qsTr("Read the exact plan"); font.pixelSize: 18 }
                                Copy { text: backend.demo ? qsTr("The full plan will list the disk, Linux partition, installer range, target OS space and ISO checksum.") : (backend.planText || qsTr("The plan will appear here after you create it.")); font.family: "Adwaita Sans"; font.pixelSize: 13 }
                            }

                            ColumnLayout {
                                visible: window.page === 3
                                Layout.fillWidth: true; spacing: 20
                                Repeater {
                                    model: [qsTr("Make room safely"),qsTr("Restart Linux once"),qsTr("Build the internal installer"),qsTr("Set a one-time installer boot")]
                                    delegate: RowLayout {
                                        required property int index
                                        required property string modelData
                                        Layout.fillWidth: true; spacing: 16
                                        Rectangle { width: 34; height: 34; radius: 17; color: window.panel; border.color: window.line
                                            Label { anchors.centerIn: parent; text: index + 1; color: window.mint; font.weight: Font.DemiBold }
                                        }
                                        Label { text: modelData; color: window.ink; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                    }
                                }
                                Rectangle { Layout.fillWidth: true; height: 1; color: window.line }
                                Heading { text: qsTr("Saved progress"); font.pixelSize: 18 }
                                Copy { text: window.progressMessage() }
                                Copy { visible: progress === "interrupted"; text: qsTr("An earlier action was interrupted. Stop here and inspect the recovery information before retrying."); color: "#ffb7a4" }
                                QuietButton { text: qsTr("Recheck readiness"); enabled: !backend.busy && !backend.demo; onClicked: backend.launch("doctor") }
                                QuietButton { visible: progress === "boot_scheduled" || progress === "interrupted"; text: qsTr("Cancel the next installer boot"); enabled: !backend.busy && !backend.demo; onClicked: { window.pendingAction = "cancel"; confirm.open() } }
                            }

                            ColumnLayout {
                                visible: window.page === 4
                                Layout.fillWidth: true; spacing: 20
                                ColumnLayout {
                                visible: progress !== "boot_restored" && !window.installerRemoved
                                Layout.fillWidth: true; spacing: 20
                                Heading { text: qsTr("Inside the installer"); font.pixelSize: 18 }
                                Copy {
                                    visible: backend.saved.windows_start !== undefined && backend.saved.windows_start !== null && backend.saved.windows_start !== ""
                                    text: qsTr("Install into %1 GiB of unallocated space on %2.").arg(((Number(backend.saved.windows_end) - Number(backend.saved.windows_start) + 1) * 512 / (1024 * 1024 * 1024)).toLocaleString(Qt.locale(), 'f', 1)).arg(backend.saved.disk || "")
                                    color: window.mint
                                }
                                CheckRow { message: qsTr("Choose only the unallocated space reserved in your plan.") }
                                CheckRow { message: qsTr("Keep Linux, EFI, recovery and installer partitions intact.") }
                                CheckRow { message: qsTr("After installation, boot Linux from the firmware menu.") }
                                Rectangle { Layout.fillWidth: true; height: 1; color: window.line }
                                }
                                Heading { visible: !window.cleanupReady && !window.installerRemoved; text: qsTr("Back in Linux"); font.pixelSize: 18 }
                                Copy { visible: !window.cleanupReady; text: window.installerRemoved ? qsTr("The installer space is now available. Keep your recovery backups and check that both systems still start.") : progress === "boot_restored" ? qsTr("Start each operating system and check your files before removing the installer.") : qsTr("Restore your previous boot priority. Keep the installer and backups until both systems boot successfully.") }
                                CheckBox { id: installed; visible: progress !== "boot_restored" && !window.installerRemoved; Layout.fillWidth: true; text: qsTr("I have installed the new system and returned to Linux"); contentItem: Label { text: installed.text; color: window.ink; wrapMode: Text.WordWrap; leftPadding: installed.indicator.width + 10; verticalAlignment: Text.AlignVCenter } }
                                QuietButton { text: qsTr("Add Windows to my boot menu"); visible: backend.direction === "windows" && !window.installerRemoved && !window.cleanupReady; enabled: progress === "boot_restored" && !backend.busy && !backend.demo; onClicked: { window.pendingAction = "windows"; confirm.open() } }
                                ColumnLayout {
                                    visible: progress === "boot_restored" && !window.installerRemoved
                                    Layout.fillWidth: true; spacing: 16
                                    Rectangle { visible: !window.cleanupReady; Layout.fillWidth: true; height: 1; color: window.line }
                                    Heading { visible: !window.cleanupReady; text: qsTr("Remove the installer"); font.pixelSize: 18 }
                                    Copy { visible: !window.cleanupReady; text: qsTr("Review the saved installer partition before freeing its space. Your system partitions keep their sizes.") }
                                    Copy { visible: backend.saved.installer_owned !== true; text: qsTr("USBless cannot identify this plan's installer safely. Open the recovery instructions to inspect it.") }
                                    Copy { visible: window.cleanupReady; color: window.ink; text: qsTr("Installer: %1 on %2, %3 GiB.").arg(backend.cleanupPreview.carrier || "").arg(backend.cleanupPreview.disk || "").arg((Number(backend.cleanupPreview.bytes || 0) / 1073741824).toLocaleString(Qt.locale(), 'f', 1)) }
                                    CheckBox {
                                        id: bothBooted
                                        objectName: "bothSystemsBooted"
                                        visible: window.cleanupReady
                                        Layout.fillWidth: true
                                        text: qsTr("Both operating systems start and my files are intact")
                                        enabled: !backend.busy && !backend.demo
                                        contentItem: Label { text: bothBooted.text; color: window.ink; wrapMode: Text.WordWrap; leftPadding: bothBooted.indicator.width + 10; verticalAlignment: Text.AlignVCenter }
                                    }
                                    QuietButton { objectName: "cleanupReviewButton"; text: window.cleanupReady ? qsTr("Review the removal plan again") : qsTr("Review installer removal"); Layout.fillWidth: window.compact; enabled: backend.saved.installer_owned === true && !backend.busy && !backend.demo; onClicked: backend.launch("cleanup-preview") }
                                }
                                QuietButton { text: qsTr("Open recovery instructions"); onClicked: backend.openRecovery() }
                                Copy { visible: backend.saved.last_backup !== undefined; text: qsTr("Recovery metadata: %1").arg(backend.saved.last_backup || ""); font.pixelSize: 12 }
                            }

                            ColumnLayout {
                                visible: window.page !== 2 && backend.logText !== ""
                                Layout.fillWidth: true; spacing: 10
                                ToolButton { id: details; text: checked ? qsTr("Hide details") : qsTr("Show details"); checkable: true }
                                Copy { visible: details.checked; text: backend.logText; font.pixelSize: 12 }
                            }
                            Item { Layout.preferredHeight: 18 }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: window.line }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: window.compact ? 100 : 88; color: "#19262f"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: window.compact ? 22 : 40; anchors.rightMargin: window.compact ? 22 : 40; spacing: 12
                        QuietButton { text: qsTr("Back"); visible: window.page > 0; onClicked: window.page--; Layout.preferredWidth: window.compact ? 68 : 90 }
                        Copy { visible: !window.compact; text: qsTr("Nothing changes without your review."); font.pixelSize: 12 }
                        Item { visible: window.compact && window.page === 0; Layout.fillWidth: true }
                        Button {
                            objectName: "primaryButton"
                            text: window.primaryText()
                            Layout.fillWidth: window.compact
                            implicitHeight: 48
                            topInset: 0
                            bottomInset: 0
                            leftPadding: 20; rightPadding: 20
                            font.weight: Font.DemiBold; font.pixelSize: window.compact ? 12 : 14
                            enabled: !backend.busy && progress !== "interrupted" && (window.page !== 4 || installed.checked || progress === "boot_restored" || window.installerRemoved) && (window.page !== 4 || !window.cleanupReady || (bothBooted.checked && !backend.demo)) && (window.page < 2 || backend.demo || ["planned","shrunk","staged","boot_scheduled","boot_restored","installer_removed"].indexOf(progress) >= 0)
                            onClicked: { if (window.page === 4 && window.cleanupReady && progress === "boot_restored") { window.pendingAction = "cleanup"; confirm.open() } else if (window.page === 4 && (progress === "boot_restored" || window.installerRemoved)) backend.refresh(); else window.advance() }
                            background: Rectangle { color: !parent.enabled ? "#40515a" : parent.down ? Qt.darker(theme.accent,1.15) : theme.accent; radius: theme.radius; border.width: parent.activeFocus ? 2 : 0; border.color: window.ink }
                            contentItem: Label { text: parent.text; color: parent.enabled ? theme.foreground : window.muted; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; wrapMode: Text.WordWrap }
                            Accessible.name: text
                        }
                    }
                }
            }
        }
    }

    Dialog {
        id: confirm
        objectName: "confirmationDialog"
        anchors.centerIn: parent
        implicitWidth: 520
        width: Math.min(window.width - 32, 520)
        modal: true
        title: window.pendingAction === "cleanup" ? qsTr("Remove the saved installer?") : qsTr("Review before continuing")
        standardButtons: Dialog.Cancel | Dialog.Ok
        onOpened: acknowledged.checked = false
        onAccepted: if (acknowledged.checked && (window.pendingAction !== "cleanup" || bothBooted.checked)) backend.launch(window.pendingAction)
        footer: DialogButtonBox {
            standardButtons: Dialog.Cancel | Dialog.Ok
            Component.onCompleted: {
                standardButton(Dialog.Ok).objectName = "confirmationProceedButton"
                standardButton(Dialog.Ok).enabled = Qt.binding(function() { return acknowledged.checked && !backend.demo && (window.pendingAction !== "cleanup" || (bothBooted.checked && window.cleanupReady)) })
                standardButton(Dialog.Ok).text = Qt.binding(function() { return window.pendingAction === "cleanup" ? qsTr("Remove installer") : qsTr("Continue") })
            }
            onAccepted: confirm.accept()
            onRejected: confirm.reject()
        }
        contentItem: ColumnLayout {
            spacing: 18
            Copy { text: window.pendingAction === "cleanup" ? qsTr("Only the installer shown in the removal plan will be removed. Keep a separate copy of your recovery backups.") : qsTr("This action can change storage or boot settings. Review the saved plan and make sure you have a separate backup."); color: window.ink }
            Copy { text: qsTr("A terminal will open for your password. USBless never receives it."); font.pixelSize: 13 }
            CheckBox { id: acknowledged; objectName: "confirmationAcknowledged"; text: qsTr("I reviewed the plan and want to continue"); Layout.fillWidth: true; contentItem: Label { text: acknowledged.text; wrapMode: Text.WordWrap; color: window.ink; leftPadding: acknowledged.indicator.width + 10 } }
        }
    }
    Connections {
        target: backend
        function onChanged() { if (!window.cleanupReady || window.installerRemoved) bothBooted.checked = false }
    }
    Dialog {
        id: shortcuts
        anchors.centerIn: parent; implicitWidth: 420; width: Math.min(window.width - 32, 420); modal: true; title: qsTr("Keyboard shortcuts"); standardButtons: Dialog.Close
        contentItem: Label { text: qsTr("Space    Continue\nAlt + Left    Back\nCtrl + R    Refresh checks\n?    This help\nQ    Quit"); color: window.ink; lineHeight: 1.6 }
    }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; onActivated: shortcuts.open() }
    Shortcut { sequence: "Ctrl+R"; context: Qt.ApplicationShortcut; onActivated: backend.refresh() }
    Shortcut { sequence: "Alt+Left"; context: Qt.ApplicationShortcut; onActivated: window.page = Math.max(0, window.page - 1) }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; enabled: !isoField.activeFocus && !backend.busy; onActivated: window.close() }
    Shortcut { sequence: "Space"; context: Qt.ApplicationShortcut; enabled: !backend.busy && !confirm.visible && window.page === 0; onActivated: window.advance() }
}
