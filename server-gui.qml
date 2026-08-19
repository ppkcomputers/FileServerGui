import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Dynamically resolves current folder path regardless of username or absolute location
    readonly property string configDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    // Dictionary mapping IP -> { user: "", pass: "" }
    property var hostCredsMap: ({})

    // Component initialization: Load per-host creds from cred.conf
    Component.onCompleted: {
        credLoader.command = ["sh", "-c", `cd "${root.configDir}" && if [ -f cred.conf ]; then cat cred.conf; fi`];
        credLoader.running = true;
    }

    // Process to parse multi-host cred.conf entries (FORMAT: IP=USER:PASS)
    Process {
        id: credLoader
        running: false
        stdout: SplitParser {
            onRead: data => {
                let lines = data.split("\n");
                let newMap = Object.assign({}, root.hostCredsMap);
                for (let line of lines) {
                    let parts = line.trim().split("=");
                    if (parts.length === 2) {
                        let ip = parts[0].trim();
                        let creds = parts[1].trim().split(":");
                        if (creds.length === 2) {
                            newMap[ip] = { user: creds[0], pass: creds[1] };
                        }
                    }
                }
                root.hostCredsMap = newMap;
                console.log("[DEBUG] Loaded persistent host credentials from cred.conf");
            }
        }
    }

    // Helper process to append/update per-host credentials in cred.conf via absolute pathing
    Process {
        id: credSaver
        running: false
        function save(ip, user, pass) {
            let script = `
            cd "${root.configDir}"
            file="cred.conf"
            touch "$file"
            if grep -q "^${ip}=" "$file"; then
                sed -i "s/^${ip}=.*/${ip}=${user}:${pass}/" "$file"
                else
                    echo "${ip}=${user}:${pass}" >> "$file"
                    fi
                    `;
                command = ["sh", "-c", script];
                running = true;
        }
    }

    PanelWindow {
        id: window
        anchors.top: true
        anchors.right: true
        exclusiveZone: 0
        implicitHeight: 1040
        implicitWidth: 860
        color: "transparent"

        onVisibleChanged: {
            if (visible && !hostScanner.running && !window.isScanningHosts && window.currentPromptHost === "") {
                if (window.discoveredHosts.length === 0 && window.pendingHosts.length === 0) {
                    console.log("[DEBUG] OSD opened for first time. Triggering LAN scan...");
                    hostScanner.startScanner();
                } else {
                    console.log("[DEBUG] OSD reopened. Preserving discovered hosts and cached session state.");
                }
            }
        }

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: window.currentPromptHost !== "" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        property var discoveredShares: []
        property var discoveredHosts: []
        property var pendingHosts: []
        property string currentPromptHost: ""
        property bool isScanningHosts: true

        property bool isDraggingFile: false
        property var draggedFileData: null
        property real dragX: 0
        property real dragY: 0
        property string hoveredHostIp: ""

        property bool isCopying: false
        property string copyFileName: ""
        property real copyProgress: 0.0
        property string copyStatusText: ""

        readonly property var playableExtensions: [
            "txt", "md", "rst", "log", "doc", "docx", "pdf",
            "conf", "config", "ini", "lua", "toml", "yaml", "yml", "json", "xml", "env", "properties",
            "service", "desktop", "rules", "theme",
            "sh", "bash", "zsh", "fish", "py", "pl", "rb", "php", "PKGBUILD", "install",
            "qml", "js", "ts", "html", "css", "c", "cpp", "h", "hpp", "rs", "go", "java", "cs", "sql",
            "png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "ico",
            "mp4", "mkv", "avi", "webm", "mov", "flv", "mp3", "flac", "wav", "ogg"
        ]

        function isFileOpenable(fileName) {
            let baseName = fileName.split('/').pop();
            if (baseName === "PKGBUILD") return true;
            let ext = fileName.split('.').pop().toLowerCase();
            return playableExtensions.includes(ext);
        }

        Component.onCompleted: {
            console.log("[DEBUG] QML Component loaded. Running universal subnet scan...");
            hostScanner.startScanner();
        }

        function processNextHost() {
            console.log("[DEBUG] Remaining pending hosts:", pendingHosts.length);
            if (pendingHosts.length > 0) {
                let nextHost = pendingHosts.shift();
                window.pendingHosts = pendingHosts;

                // Check if specific host credentials exist in hostCredsMap
                let creds = root.hostCredsMap[nextHost];
                if (creds && creds.user !== undefined) {
                    console.log(`[DEBUG] Attempting cached credentials (${creds.user}) on host: ${nextHost}...`);
                    shareScanner.runScanner(nextHost, creds.user, creds.pass, true);
                } else {
                    window.currentPromptHost = nextHost;
                    console.log("[DEBUG] Prompting user for host:", nextHost);
                }
            } else {
                console.log("[DEBUG] Host queue empty. Discovery finished.");
                window.currentPromptHost = "";
            }
        }

        function submitCredentials(user, pass) {
            let target = window.currentPromptHost;
            console.log(`[DEBUG] Querying shares on ${target} | User: '${user}'`);
            window.currentPromptHost = "";

            if (user.trim() !== "" || pass.trim() !== "") {
                let newMap = Object.assign({}, root.hostCredsMap);
                newMap[target] = { user: user, pass: pass };
                root.hostCredsMap = newMap;
                credSaver.save(target, user, pass);
                console.log(`[DEBUG] Saved credentials for '${target}' into cred.conf.`);
            }

            shareScanner.runScanner(target, user, pass, false);

            userInput.text = "";
            passInput.text = "";
        }

        function getSharesForHost(ip) {
            return discoveredShares.filter(item => item.host === ip);
        }

        function updateHoveredColumn(gx, gy) {
            let foundIp = "";
            for (let i = 0; i < window.discoveredHosts.length; i++) {
                let colItem = columnsListView.itemAtIndex(i);
                if (colItem) {
                    let mapped = colItem.mapFromItem(body, gx, gy);
                    if (mapped.x >= 0 && mapped.x <= colItem.width && mapped.y >= 0 && mapped.y <= colItem.height) {
                        if (colItem.activeShare !== "") {
                            foundIp = colItem.modelData;
                        }
                        break;
                    }
                }
            }
            window.hoveredHostIp = foundIp;
        }

        Rectangle {
            id: body
            x: window.implicitWidth
            y: 20
            width: parent.width - 40
            height: parent.height - 40
            radius: 16
            color: Qt.rgba(0, 0, 0, 0.88)
            border.width: 3
            border.color: "#535337"

            Behavior on x {
                NumberAnimation { duration: 500; easing.type: Easing.OutCubic }
            }

            Column {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 16

                Row {
                    width: parent.width
                    height: 40
                    spacing: 12

                    Text {
                        text: window.isScanningHosts ? "⏳ Scanning Subnet for SMB (Port 445)..." :
                        (window.currentPromptHost !== "" ? "🔒 Credentials Required" : "✅ Discovery Complete")
                        color: window.isScanningHosts ? "#e5c07b" : "#98c379"
                        font.pixelSize: 18
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideMiddle
                    }
                }

                Rectangle {
                    width: parent.width
                    height: window.isCopying ? 70 : 0
                    visible: window.isCopying
                    color: Qt.rgba(1, 1, 1, 0.08)
                    radius: 10
                    border.width: 1
                    border.color: "#a5a25e"
                    clip: true

                    Behavior on height { NumberAnimation { duration: 200 } }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6

                        Row {
                            width: parent.width
                            Text {
                                text: "📦 Copying " + window.copyFileName + "..."
                                color: "white"
                                font.pixelSize: 14
                                font.bold: true
                                width: parent.width - 80
                                elide: Text.ElideRight
                            }
                            Text {
                                text: Math.round(window.copyProgress * 100) + "%"
                                color: "#a5a25e"
                                font.pixelSize: 14
                                font.bold: true
                                horizontalAlignment: Text.AlignRight
                                width: 80
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 14
                            color: "#222"
                            radius: 7

                            Rectangle {
                                width: parent.width * window.copyProgress
                                height: parent.height
                                color: "#a5a25e"
                                radius: 7
                                Behavior on width { NumberAnimation { duration: 100 } }
                            }
                        }

                        Text {
                            text: window.copyStatusText
                            color: "#aaa"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: window.currentPromptHost !== "" ? 220 : 0
                    visible: window.currentPromptHost !== ""
                    color: Qt.rgba(1, 1, 1, 0.08)
                    radius: 10
                    border.width: 2
                    border.color: "#e5c07b"
                    clip: true

                    Behavior on height { NumberAnimation { duration: 200 } }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 12

                        Text {
                            text: "Enter Credentials for Host: " + window.currentPromptHost
                            color: "white"
                            font.pixelSize: 18
                            font.bold: true
                        }

                        Row {
                            spacing: 12
                            width: parent.width
                            Text { text: "User:"; color: "#ccc"; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter; width: 60 }
                            TextField {
                                id: userInput
                                width: parent.width - 80
                                height: 40
                                placeholderText: "Leave blank for Guest"
                                color: "white"
                                font.pixelSize: 15
                                focus: window.currentPromptHost !== ""
                                background: Rectangle { color: "#222"; radius: 6 }
                            }
                        }

                        Row {
                            spacing: 12
                            width: parent.width
                            Text { text: "Pass:"; color: "#ccc"; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter; width: 60 }
                            TextField {
                                id: passInput
                                width: parent.width - 80
                                height: 40
                                echoMode: TextInput.Password
                                color: "white"
                                font.pixelSize: 15
                                background: Rectangle { color: "#222"; radius: 6 }
                                onAccepted: window.submitCredentials(userInput.text, passInput.text)
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 40
                            color: "#606445"
                            radius: 6
                            Text {
                                anchors.centerIn: parent
                                text: "Connect & Fetch Shares"
                                color: "white"
                                font.pixelSize: 16
                                font.bold: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: window.submitCredentials(userInput.text, passInput.text)
                            }
                        }
                    }
                }

                Text {
                    text: "Discovered Host SMB Columns:"
                    color: "#a0a0a0"
                    font.pixelSize: 15
                }

                Rectangle {
                    id: mainContainer
                    width: parent.width
                    height: parent.height - y - 10
                    color: Qt.rgba(1, 1, 1, 0.07)
                    radius: 10
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.12)
                    clip: true

                    ListView {
                        id: columnsListView
                        anchors.fill: parent
                        anchors.margins: 12
                        orientation: ListView.Horizontal
                        spacing: 14
                        clip: true

                        model: window.discoveredHosts

                        delegate: Rectangle {
                            required property var modelData
                            id: hostColumn
                            width: 260
                            height: ListView.view.height
                            color: isTargetHovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.05)
                            radius: 8
                            border.width: isTargetHovered ? 2 : 1
                            border.color: isTargetHovered ? "#98c379" : Qt.rgba(1, 1, 1, 0.1)

                            property string activeShare: ""
                            property string activeUser: ""
                            property string activePass: ""
                            property string currentPath: ""
                            property var shareContents: []

                            property bool isTargetHovered: window.isDraggingFile && window.hoveredHostIp === hostColumn.modelData

                            Column {
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 10

                                Rectangle {
                                    width: parent.width
                                    height: 34
                                    color: "#535337"
                                    radius: 6

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        spacing: 6

                                        Rectangle {
                                            width: 55
                                            height: parent.height
                                            color: "#606445"
                                            radius: 4
                                            visible: hostColumn.activeShare !== ""

                                            Text {
                                                anchors.centerIn: parent
                                                text: "← Back"
                                                color: "white"
                                                font.pixelSize: 12
                                                font.bold: true
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: {
                                                    if (hostColumn.currentPath !== "") {
                                                        let parts = hostColumn.currentPath.split("\\").filter(p => p.length > 0);
                                                        parts.pop();
                                                        let parentPath = parts.join("\\");
                                                        shareContentFetcher.fetchContents(hostColumn, hostColumn.modelData, hostColumn.activeShare, hostColumn.activeUser, hostColumn.activePass, parentPath);
                                                    } else {
                                                        hostColumn.activeShare = "";
                                                        hostColumn.shareContents = [];
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            width: parent.width - (hostColumn.activeShare !== "" ? 61 : 0)
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: hostColumn.activeShare !== "" ? "/" + hostColumn.activeShare + (hostColumn.currentPath ? "/" + hostColumn.currentPath.replace(/\\/g, "/") : "") : "🖥️ " + hostColumn.modelData
                                            color: "white"
                                            font.pixelSize: 14
                                            font.bold: true
                                            elide: Text.ElideMiddle
                                            horizontalAlignment: hostColumn.activeShare !== "" ? Text.AlignLeft : Text.AlignHCenter
                                        }
                                    }
                                }

                                ListView {
                                    width: parent.width
                                    height: parent.height - 44
                                    visible: hostColumn.activeShare === ""
                                    spacing: 8
                                    clip: true

                                    model: window.getSharesForHost(hostColumn.modelData)

                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width
                                        height: 44
                                        color: shareMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.08)
                                        radius: 6

                                        Row {
                                            anchors.fill: parent
                                            anchors.leftMargin: 12
                                            spacing: 10

                                            Text { text: "📁"; font.pixelSize: 16; anchors.verticalCenter: parent.verticalCenter }
                                            Text {
                                                text: modelData.share
                                                color: "#c0c0c1"
                                                font.pixelSize: 16
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                                elide: Text.ElideRight
                                            }
                                        }

                                        MouseArea {
                                            id: shareMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: {
                                                hostColumn.activeUser = modelData.user;
                                                hostColumn.activePass = modelData.pass;
                                                shareContentFetcher.fetchContents(hostColumn, modelData.host, modelData.share, modelData.user, modelData.pass, "");
                                            }
                                        }
                                    }
                                }

                                ListView {
                                    width: parent.width
                                    height: parent.height - 44
                                    visible: hostColumn.activeShare !== ""
                                    spacing: 6
                                    clip: true

                                    model: hostColumn.shareContents

                                    delegate: Item {
                                        required property var modelData
                                        width: ListView.view.width
                                        height: 36

                                        Rectangle {
                                            id: fileItemContainer
                                            anchors.fill: parent
                                            color: itemMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.08)
                                            radius: 6

                                            Row {
                                                anchors.fill: parent
                                                anchors.leftMargin: 10
                                                spacing: 10

                                                Text { text: modelData.isDir ? "📁" : "📄"; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                                                Text {
                                                    text: modelData.name
                                                    color: modelData.isDir ? "#e5c07b" : (window.isFileOpenable(modelData.name) ? "#61afef" : "white")
                                                    font.pixelSize: 14
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            MouseArea {
                                                id: itemMouse
                                                anchors.fill: parent
                                                acceptedButtons: Qt.LeftButton
                                                hoverEnabled: true

                                                property point pressPos: "0,0"

                                                onPressed: mouse => {
                                                    if (mouse.button === Qt.LeftButton) {
                                                        pressPos = Qt.point(mouse.x, mouse.y);
                                                    }
                                                }

                                                onPositionChanged: mouse => {
                                                    if (mouse.buttons & Qt.LeftButton) {
                                                        let distance = Math.sqrt(Math.pow(mouse.x - pressPos.x, 2) + Math.pow(mouse.y - pressPos.y, 2));
                                                        if (distance > 6 && !window.isDraggingFile && !modelData.isDir) {
                                                            window.isDraggingFile = true;
                                                            window.draggedFileData = {
                                                                host: hostColumn.modelData,
                                                                share: hostColumn.activeShare,
                                                                user: hostColumn.activeUser,
                                                                pass: hostColumn.activePass,
                                                                path: hostColumn.currentPath,
                                                                name: modelData.name
                                                            };
                                                            let globalPos = mapToItem(body, mouse.x, mouse.y);
                                                            window.dragX = globalPos.x;
                                                            window.dragY = globalPos.y;
                                                            window.updateHoveredColumn(globalPos.x, globalPos.y);
                                                        }
                                                    }
                                                }

                                                onClicked: mouse => {
                                                    if (mouse.button === Qt.LeftButton && modelData.isDir) {
                                                        let newSubPath = hostColumn.currentPath !== "" ? (hostColumn.currentPath + "\\" + modelData.name) : modelData.name;
                                                        shareContentFetcher.fetchContents(hostColumn, hostColumn.modelData, hostColumn.activeShare, hostColumn.activeUser, hostColumn.activePass, newSubPath);
                                                    }
                                                }

                                                onDoubleClicked: mouse => {
                                                    if (mouse.button === Qt.LeftButton && !modelData.isDir && window.isFileOpenable(modelData.name)) {
                                                        fileOpener.openRemoteFile(hostColumn.modelData, hostColumn.activeShare, hostColumn.activeUser, hostColumn.activePass, hostColumn.currentPath, modelData.name);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            MouseArea {
                id: globalDragOverlay
                anchors.fill: parent
                visible: window.isDraggingFile
                z: 9998
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true

                onPositionChanged: mouse => {
                    window.dragX = mouse.x;
                    window.dragY = mouse.y;
                    window.updateHoveredColumn(mouse.x, mouse.y);
                }

                onReleased: mouse => {
                    if (window.isDraggingFile) {
                        window.updateHoveredColumn(mouse.x, mouse.y);

                        if (window.hoveredHostIp !== "") {
                            for (let i = 0; i < window.discoveredHosts.length; i++) {
                                let colItem = columnsListView.itemAtIndex(i);
                                if (colItem && colItem.modelData === window.hoveredHostIp) {
                                    let src = window.draggedFileData;
                                    let dstHost = colItem.modelData;
                                    let dstShare = colItem.activeShare;
                                    let dstUser = colItem.activeUser;
                                    let dstPass = colItem.activePass;
                                    let dstPath = colItem.currentPath;

                                    if (src && (src.host !== dstHost || src.share !== dstShare || src.path !== dstPath)) {
                                        console.log(`[DEBUG] Executing Column Drag Transfer: ${src.name} -> ${dstHost}/${dstShare}/${dstPath}`);
                                        fileCopier.copyFileBetweenShares(src, colItem, dstHost, dstShare, dstUser, dstPass, dstPath);
                                    }
                                    break;
                                }
                            }
                        }

                        window.isDraggingFile = false;
                        window.draggedFileData = null;
                        window.hoveredHostIp = "";
                    }
                }
            }

            Rectangle {
                id: dragGhost
                width: 180
                height: 32
                color: "#606445"
                radius: 6
                border.width: 1
                border.color: "white"
                visible: window.isDraggingFile
                x: window.dragX - width / 2
                y: window.dragY - height / 2
                z: 9999

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Text { text: "📦"; font.pixelSize: 14 }
                    Text {
                        text: window.draggedFileData ? window.draggedFileData.name : ""
                        color: "white"
                        font.pixelSize: 13
                        font.bold: true
                        elide: Text.ElideRight
                        width: 130
                    }
                }
            }
        }

        Process {
            id: hostScanner
            running: false

            function startScanner() {
                window.isScanningHosts = true;
                command = [
                    "sh", "-c",
                    `dev=$(ip route show default | awk '{print $5}'); ` +
                    `ip_prefix=$(ip -o -4 addr show "$dev" | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3); ` +
                    `nmap -n -Pn -p 445 --open "$ip_prefix.0/24" -oG - | awk '/Up$/ {print $2}'`
                ];
                console.log("[DEBUG] Executing unprivileged nmap port 445 scan...");
                running = true;
            }

            stdout: SplitParser {
                onRead: data => {
                    let ip = data.trim();
                    console.log("[DEBUG] [Discovered Host IP]:", ip);
                    if (ip !== "") {
                        let arr = Array.from(window.pendingHosts);
                        let discovered = Array.from(window.discoveredHosts);
                        if (!arr.includes(ip) && !discovered.includes(ip)) {
                            arr.push(ip);
                            window.pendingHosts = arr;
                        }
                    }
                }
            }

            stderr: SplitParser {
                onRead: data => console.log("[DEBUG] [hostScanner STDERR]:", data.trim())
            }

            onExited: (exitCode, status) => {
                console.log(`[DEBUG] hostScanner finished with code: ${exitCode}`);
                window.isScanningHosts = false;
                if (window.currentPromptHost === "") {
                    window.processNextHost();
                }
            }
        }

        Process {
            id: shareScanner
            running: false
            property string targetIp: ""
            property string targetUser: ""
            property string targetPass: ""
            property bool isAutoTryingCache: false
            property bool foundSharesForTarget: false

            function runScanner(ip, user, pass, isAutoCache) {
                targetIp = ip;
                targetUser = user;
                targetPass = pass;
                isAutoTryingCache = isAutoCache;
                foundSharesForTarget = false;

                let credArgs = (user === "" && pass === "") ? "-N" : `-U "${user}%${pass}"`;

                command = [
                    "sh", "-c",
                    `smbclient -L "//${ip}" ${credArgs} -g 2>&1 | grep "^Disk|" | cut -d'|' -f2`
                ];
                console.log(`[DEBUG] Executing shareScanner for host ${ip}...`);
                running = true;
            }

            stdout: SplitParser {
                onRead: data => {
                    let shareName = data.trim();
                    if (shareName !== "" && !shareName.endsWith("$")) {
                        console.log(`[DEBUG] [Found Share on ${shareScanner.targetIp}]:`, shareName);
                        shareScanner.foundSharesForTarget = true;

                        let hosts = Array.from(window.discoveredHosts);
                        if (!hosts.includes(shareScanner.targetIp)) {
                            hosts.push(shareScanner.targetIp);
                            window.discoveredHosts = hosts;
                        }

                        let shares = Array.from(window.discoveredShares);
                        let exists = shares.some(s => s.host === shareScanner.targetIp && s.share === shareName);
                        if (!exists) {
                            shares.push({
                                host: shareScanner.targetIp,
                                share: shareName,
                                user: shareScanner.targetUser,
                                pass: shareScanner.targetPass
                            });
                            window.discoveredShares = shares;
                        }
                    }
                }
            }

            stderr: SplitParser {
                onRead: data => console.log("[DEBUG] [shareScanner STDERR]:", data.trim())
            }

            onExited: (exitCode, status) => {
                console.log(`[DEBUG] shareScanner finished for ${targetIp} with code: ${exitCode}`);
                if (shareScanner.isAutoTryingCache && !shareScanner.foundSharesForTarget) {
                    console.log(`[DEBUG] Cached credentials failed or returned no shares on host ${targetIp}. Prompting user...`);
                    window.currentPromptHost = targetIp;
                } else {
                    window.processNextHost();
                }
            }
        }

        Process {
            id: shareContentFetcher
            running: false
            property var targetColumn: null

            function fetchContents(columnRef, host, share, user, pass, subPath) {
                targetColumn = columnRef;
                targetColumn.activeShare = share;
                targetColumn.currentPath = subPath;
                targetColumn.shareContents = [];

                let credArgs = (user === "" && pass === "") ? "-N" : `-U "${user}%${pass}"`;
                let cdCmd = subPath ? `cd "${subPath}"; ` : "";

                command = [
                    "sh", "-c",
                    `smbclient "//${host}/${share}" ${credArgs} -c '${cdCmd}dir *' 2>/dev/null | awk 'NF>=2 && $1 != "." && $1 != ".." && $1 != "BLOCKS" {is_dir = ($0 ~ /\\<D\\>|\\<DIR\\>/) ? "1" : "0"; print $1 "|" is_dir}'`
                ];
                console.log(`[DEBUG] Fetching contents for //${host}/${share}/${subPath}...`);
                running = true;
            }

            stdout: SplitParser {
                onRead: data => {
                    let parts = data.trim().split("|");
                    if (parts.length === 2 && parts[0] !== "" && parts[0] !== "." && parts[0] !== ".." && shareContentFetcher.targetColumn) {
                        let current = Array.from(shareContentFetcher.targetColumn.shareContents);
                        current.push({ name: parts[0], isDir: parts[1] === "1" });
                        shareContentFetcher.targetColumn.shareContents = current;
                    }
                }
            }

            stderr: SplitParser {
                onRead: data => console.log("[DEBUG] [shareContentFetcher STDERR]:", data.trim())
            }
        }

        Process {
            id: fileOpener
            running: false
            property string targetFilePath: ""

            function openRemoteFile(host, share, user, pass, subPath, fileName) {
                let localPath = `/tmp/qs_smb_${fileName}`;
                targetFilePath = localPath;

                let credArgs = (user === "" && pass === "") ? "-N" : `-U "${user}%${pass}"`;
                let cdCmd = subPath ? `cd "${subPath}"; ` : "";

                command = [
                    "sh", "-c",
                    `smbclient "//${host}/${share}" ${credArgs} -c '${cdCmd}get "${fileName}" "${localPath}"' 2>/dev/null`
                ];
                console.log(`[DEBUG] Fetching file //${host}/${share}/${subPath}/${fileName} to ${localPath}...`);
                running = true;
            }

            onExited: (exitCode, status) => {
                if (exitCode === 0) {
                    console.log("[DEBUG] Executing dynamic editor resolution for:", targetFilePath);

                    let script = `
                    file="${targetFilePath}"
                    if xdg-open "$file" 2>/dev/null; then
                        exit 0
                        fi

                        editors="zed code kate kwrite gnome-text-editor nvim nano"
                        for ed in $editors; do
                            if command -v "$ed" >/dev/null 2>&1; then
                                case "$ed" in
                                nvim|nano)
                                if command -v xterm >/dev/null 2>&1; then
                                    xterm -e "$ed" "$file" &
                                    elif command -v kitty >/dev/null 2>&1; then
                                    kitty "$ed" "$file" &
                                    elif command -v alacritty >/dev/null 2>&1; then
                                    alacritty -e "$ed" "$file" &
                                    else
                                        $ed "$file" &
                                        fi
                                        ;;
                                    *)
                                    "$ed" "$file" &
                                    ;;
                                    esac
                                    exit 0
                                    fi
                                    done
                                    `;

                                    editorLauncher.command = ["sh", "-c", script];
                                    editorLauncher.running = true;
                } else {
                    console.log("[DEBUG] Failed to download remote file for opening.");
                }
            }
        }

        Process {
            id: editorLauncher
            running: false
            stderr: SplitParser {
                onRead: data => console.log("[DEBUG] [editorLauncher STDERR]:", data.trim())
            }
        }

        Process {
            id: fileCopier
            running: false
            property var destColumn: null
            property string destHost: ""
            property string destShare: ""
            property string destUser: ""
            property string destPass: ""
            property string destPath: ""

            function copyFileBetweenShares(sourceObj, columnRef, toHost, toShare, toUser, toPass, toPath) {
                destColumn = columnRef;
                destHost = toHost;
                destShare = toShare;
                destUser = toUser;
                destPass = toPass;
                destPath = toPath;

                window.isCopying = true;
                window.copyFileName = sourceObj.name;
                window.copyProgress = 0.05;
                window.copyStatusText = "Downloading source file to local cache...";

                let srcCreds = (sourceObj.user === "" && sourceObj.pass === "") ? "-N" : `-U "${sourceObj.user}%${sourceObj.pass}"`;
                let dstCreds = (toUser === "" && toPass === "") ? "-N" : `-U "${toUser}%${toPass}"`;

                let srcCd = sourceObj.path ? `cd "${sourceObj.path}"; ` : "";
                let dstCd = toPath ? `cd "${toPath}"; ` : "";

                let tmpFile = `/tmp/drag_smb_${sourceObj.name}`;

                command = [
                    "sh", "-c",
                    `smbclient "//${sourceObj.host}/${sourceObj.share}" ${srcCreds} -c '${srcCd}get "${sourceObj.name}" "${tmpFile}"' 2>&1 | stdbuf -oL tr '\\r' '\\n' && ` +
                    `echo "---PHASE2---" && ` +
                    `smbclient "//${toHost}/${toShare}" ${dstCreds} -c '${dstCd}put "${tmpFile}" "${sourceObj.name}"' 2>&1 | stdbuf -oL tr '\\r' '\\n' && ` +
                    `rm -f "${tmpFile}"`
                ];
                running = true;
            }

            stdout: SplitParser {
                onRead: data => {
                    let line = data.trim();
                    if (line.includes("---PHASE2---")) {
                        window.copyProgress = 0.50;
                        window.copyStatusText = "Uploading file to target SMB share...";
                    } else {
                        let pctMatch = line.match(/([0-9]{1,3})\s*%/);
                        if (pctMatch && pctMatch[1]) {
                            let pct = parseInt(pctMatch[1]) / 100.0;
                            if (window.copyProgress < 0.50) {
                                window.copyProgress = Math.max(0.05, pct * 0.50);
                            } else {
                                window.copyProgress = Math.max(0.50, 0.50 + (pct * 0.50));
                            }
                        }
                        if (line !== "") {
                            window.copyStatusText = line;
                        }
                    }
                }
            }

            stderr: SplitParser {
                onRead: data => console.log("[DEBUG] [fileCopier STDERR]:", data.trim())
            }

            onExited: (exitCode, status) => {
                window.copyProgress = 1.0;
                window.isCopying = false;

                if (exitCode === 0 && destColumn) {
                    console.log(`[DEBUG] Drag Copy Successful! Refreshing ${destHost}/${destShare}/${destPath}...`);
                    shareContentFetcher.fetchContents(destColumn, destHost, destShare, destUser, destPass, destPath);
                } else {
                    console.log("[DEBUG] Inter-share drag copy failed.");
                }
            }
        }

        Timer {
            interval: 80
            running: true
            repeat: false
            onTriggered: {
                body.x = 20;
            }
        }
    }
}
