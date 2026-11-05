import QtQuick 2.0
import AppEngineerMode_Enum 1.0
import "../System"
import "../Component" as MComp
// OwnerTools: on-HU owner-management page, opened from the Full Engineering Mode menu
// via Global.popupQmlOpen("/app/share/AppEngineerMode/qml/owner/OwnerTools.qml","").
// Buttons call ONLY natives proven present in AppEngineerMode (see v2 README §menu).
// Owner's own decommissioned car; benign.
MComp.MComponent {
    id: idOwnerTools
    width: SystemConst.lcdWidth
    height: SystemConst.lcdHeight
    clip: true
    focus: true

    function log(m){ AppEngineerModeEngine.qmlLog("[OwnerTools] " + m) }

    MComp.MBand {
        id: idOwnerBand
        titleText: qsTr("Owner Tools")
        onBackKeyClicked: { Global.popupQmlClose ? Global.popupQmlClose() : AppEngineerModeEngine.handleBackKey() }
    }

    Text {
        id: idStatus
        x: 80; y: 120; color: "white"; font.pixelSize: 26
        text: "Owner Tools — SSH over built-in Wi-Fi (" +
              ((typeof WiFiDebugScreenHandler !== "undefined" && WiFiDebugScreenHandler.getWiFiDriverStatus)
                  ? WiFiDebugScreenHandler.getWiFiDriverStatus() : "AP: IONIQ5-OWNER") + ")"
    }

    Column {
        x: 80; y: 190; spacing: 24
        MComp.MMainButton {
            firstText: "Open firewall (iptables ACCEPT)"
            onClickOrKeySelected: { IPInfo.setIPTableDebug(1); idOwnerTools.log("iptables ACCEPT") }
        }
        MComp.MMainButton {
            firstText: "Extract logs to USB"
            onClickOrKeySelected: { SystemControl.setLogModeOn(); idOwnerTools.log("log mode on") }
        }
        // NOTE: starting Wi-Fi+SSH from the menu needs a native->script hook confirmed on-device
        // (see README open-item). The boot service (owner-access.service) already does this at
        // startup; this button is wired to the firewall-open native as the reliable proven action.
        MComp.MMainButton {
            firstText: "Re-open network for SSH"
            onClickOrKeySelected: { IPInfo.setIPTableDebug(1); idOwnerTools.log("re-open net") }
        }
    }
}
