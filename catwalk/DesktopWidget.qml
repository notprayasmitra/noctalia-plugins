import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Modules.DesktopWidgets
import qs.Widgets
import qs.Services.System

DraggableDesktopWidget {
    id: root
    property var pluginApi: null

    implicitWidth: 200
    implicitHeight: 80

    showBackground: false

    property int frameIndex: 0
    property bool isRunning: true
    
    readonly property var icons: [
        "icons/my-active-0-symbolic.svg",
        "icons/my-active-1-symbolic.svg",
        "icons/my-active-2-symbolic.svg",
        "icons/my-active-3-symbolic.svg",
        "icons/my-active-4-symbolic.svg"
    ]
    
    property int idleFrameIndex: 0
    readonly property var idleIcons: [
        "icons/my-idle-0-symbolic.svg",
        "icons/my-idle-1-symbolic.svg",
        "icons/my-idle-2-symbolic.svg",
        "icons/my-idle-3-symbolic.svg"
    ]

    property real cpuUsage: SystemStatService.cpuUsage

    Timer {
        interval: Math.max(30, 200 - root.cpuUsage * 1.7)
        running: root.isRunning && root.cpuUsage >= (pluginApi?.pluginSettings?.minimumThreshold || 10)
        repeat: true
        onTriggered: {
            root.frameIndex = (root.frameIndex + 1) % root.icons.length
        }
    }
    
    Timer {
        interval: 400
        running: root.isRunning && root.cpuUsage < (pluginApi?.pluginSettings?.minimumThreshold || 10)
        repeat: true
        onTriggered: {
            root.idleFrameIndex = (root.idleFrameIndex + 1) % root.idleIcons.length
        }
    }

    property url currentIconSource: (root.isRunning && root.cpuUsage >= (pluginApi?.pluginSettings?.minimumThreshold || 10)) 
                       ? Qt.resolvedUrl(root.icons[root.frameIndex]) 
                       : Qt.resolvedUrl(root.idleIcons[root.idleFrameIndex])

    RowLayout {
        anchors.fill: parent
        spacing: 5
        
        Image {
            id: iconImage
            source: root.currentIconSource
            Layout.fillHeight: true
            Layout.preferredWidth: height
            
            sourceSize.height: height
            sourceSize.width: width
            
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: false 

            layer.enabled: true
            layer.effect: MultiEffect {
                colorization: 1.0
                colorizationColor: Settings.data.colorSchemes.darkMode ? "white" : "black"
            }
        }

        Text {
            text: Math.round(root.cpuUsage) + "%"
            color: Settings.data.colorSchemes.darkMode ? "white" : "black"
            font.bold: true
            font.pixelSize: 40
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
