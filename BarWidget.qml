import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "NightlightModel.js" as NightlightModel

// Moon button for the bar, plus its settings popup. One unified period:
// the start and end can each independently be a fixed clock time or linked
// to sunset/sunrise (live, updated daily), with a shared transition
// duration for whichever edges are linked. The Turn on/off button is a
// temporary override on top of that, not a separate mode. The service
// (Service.qml) owns the actual scheduling loop and keeps running whether
// or not this popup is open; this widget only reads it for display and
// writes changes back to shell.json.
BarWidget {
  id: root
  moduleName: "darksamen.nightlight"

  readonly property var nightlightService: bar?.shell?.firstPartyServiceFor("darksamen.nightlight")
  readonly property bool enabled: nightlightService ? nightlightService.enabled : false
  readonly property int temperature: nightlightService && nightlightService.temperature !== null && nightlightService.temperature !== undefined ? nightlightService.temperature : 0
  readonly property bool startLinkedToSun: nightlightService ? nightlightService.startLinkedToSun : false
  readonly property bool endLinkedToSun: nightlightService ? nightlightService.endLinkedToSun : false
  readonly property bool hasLocation: nightlightService ? nightlightService.hasLocation : false
  readonly property string sunriseLabel: nightlightService ? nightlightService.sunriseLabel : "--:--"
  readonly property string sunsetLabel: nightlightService ? nightlightService.sunsetLabel : "--:--"
  readonly property int sunTransitionMinutes: nightlightService ? nightlightService.sunTransitionMinutes : 30

  readonly property string statusLabel: {
    var state = enabled ? "On" : "Off"
    var tempTxt = temperature > 0 ? " · " + temperature + "K" : ""
    return state + tempTxt
  }

  property bool popupOpen: false
  function close() { popupOpen = false }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]

    // Applied locally first so the panel reflects the edit immediately; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // While an edge is sun-linked its field shows the live sunset/sunrise
  // time (read-only, disabled) instead of the manually-typed value —
  // toggling the link off reveals that manual value again untouched, since
  // it's never overwritten while linked (only the "linked" flag changes;
  // scheduleStart/scheduleEnd keep whatever was last typed).
  function refreshStartDisplay() {
    startTimeField.text = root.startLinkedToSun
      ? root.sunsetLabel
      : (nightlightService ? nightlightService.scheduleStart : "20:00")
  }

  function refreshEndDisplay() {
    endTimeField.text = root.endLinkedToSun
      ? root.sunriseLabel
      : (nightlightService ? nightlightService.scheduleEnd : "07:00")
  }

  // Repopulates the free-typed fields from the live service values. Called
  // once at startup and every time the popup opens, so a change made
  // elsewhere (another monitor's copy of this widget, a hand edit) shows up
  // without clobbering whatever the user is mid-typing while it's open.
  function syncFields() {
    root.refreshStartDisplay()
    root.refreshEndDisplay()
    transitionField.text = String(root.sunTransitionMinutes)
  }

  onPopupOpenChanged: if (popupOpen) Qt.callLater(root.syncFields)
  Component.onCompleted: root.syncFields()
  onStartLinkedToSunChanged: root.refreshStartDisplay()
  onEndLinkedToSunChanged: root.refreshEndDisplay()
  onSunsetLabelChanged: if (root.startLinkedToSun) root.refreshStartDisplay()
  onSunriseLabelChanged: if (root.endLinkedToSun) root.refreshEndDisplay()

  function commitScheduleStart() {
    var formatted = NightlightModel.clampTimeText(startTimeField.text)
    if (!formatted) formatted = nightlightService ? nightlightService.scheduleStart : "20:00"
    startTimeField.text = formatted
    root.persistSettings({ scheduleStart: formatted })
  }

  function commitScheduleEnd() {
    var formatted = NightlightModel.clampTimeText(endTimeField.text)
    if (!formatted) formatted = nightlightService ? nightlightService.scheduleEnd : "07:00"
    endTimeField.text = formatted
    root.persistSettings({ scheduleEnd: formatted })
  }

  function commitTransition() {
    var minutes = parseInt(transitionField.text, 10)
    if (isNaN(minutes)) minutes = root.sunTransitionMinutes
    minutes = Math.max(0, Math.min(120, minutes))
    transitionField.text = String(minutes)
    root.persistSettings({ sunTransitionMinutes: minutes })
  }

  function toggleStartSunLink() { root.persistSettings({ startLinkedToSun: !root.startLinkedToSun }) }
  function toggleEndSunLink() { root.persistSettings({ endLinkedToSun: !root.endLinkedToSun }) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    active: root.enabled
    // Off: the normal bar foreground (white). On: the theme accent — the
    // same color as the active-window border — rather than a brightness
    // change, so the icon reads as "on" at a glance.
    activeColor: Color.accent
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: root.statusLabel

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.nightlightService) root.nightlightService.toggle()
        return
      }
      root.popupOpen = !root.popupOpen
    }
  }

  // KeyboardPanel (not the simpler PopupCard) because this panel has real
  // text fields: PopupCard's window never accepts keyboard focus (it maps
  // to a non-activatable surface, fine for the button-only popups it was
  // built for), so nothing here could actually be typed into.
  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(336))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Panel-navigation keys (Escape/Tab/arrows/Enter/Space) are only
      // meaningful when focus isn't already inside one of our own text
      // fields — otherwise Escape/Enter/arrows would be stolen from the
      // field instead of editing it.
      blocked: startTimeField.activeFocus || endTimeField.activeFocus || transitionField.activeFocus
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: moon · title/status · quick override toggle ----------
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroIcon
            text: "󰔎"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - heroIcon.width - toggleButton.width - parent.spacing * 2
            spacing: Style.space(2)

            Text {
              text: "Night light"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusLabel
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Button {
            id: toggleButton
            anchors.verticalCenter: parent.verticalCenter
            text: root.enabled ? "Turn off" : "Turn on"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: if (root.nightlightService) root.nightlightService.toggle()
          }
        }

        PanelSeparator {
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        // ---------- Period: fixed times on top, sun-link toggles below ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "PERIOD"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Grid {
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.space(6)

            Text {
              text: "Period start"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              text: "Period end"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: startTimeField
              enabled: !root.startLinkedToSun
              opacity: enabled ? 1.0 : 0.45
              inputMask: "99:99;_"
              horizontalAlignment: TextInput.AlignHCenter
              width: Style.space(140)
              foreground: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onEditingFinished: root.commitScheduleStart()
              Keys.onReturnPressed: root.commitScheduleStart()
              Keys.onEnterPressed: root.commitScheduleStart()
            }

            TextField {
              id: endTimeField
              enabled: !root.endLinkedToSun
              opacity: enabled ? 1.0 : 0.45
              inputMask: "99:99;_"
              horizontalAlignment: TextInput.AlignHCenter
              width: Style.space(140)
              foreground: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onEditingFinished: root.commitScheduleEnd()
              Keys.onReturnPressed: root.commitScheduleEnd()
              Keys.onEnterPressed: root.commitScheduleEnd()
            }

            // Same width as the field above so it sits centered under it —
            // the button's own text is centered within that width too.
            Button {
              width: Style.space(140)
              text: "Sunset"
              selected: root.startLinkedToSun
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.toggleStartSunLink()
            }

            Button {
              width: Style.space(140)
              text: "Sunrise"
              selected: root.endLinkedToSun
              bordered: true
              foreground: root.bar ? root.bar.foreground : Color.foreground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.toggleEndSunLink()
            }
          }

          Text {
            visible: (root.startLinkedToSun || root.endLinkedToSun) && !root.hasLocation
            text: "No location set — open the weather widget to set one."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Column {
            spacing: Style.space(4)

            Text {
              text: "Transition duration (minutes)"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: transitionField
              // Digits only, no range limit here — typing "999" has to reach
              // the field so committing it can visibly clamp to 120, rather
              // than a range-limited validator silently swallowing keystrokes
              // once the field would exceed the cap.
              validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,3}$/ }
              horizontalAlignment: TextInput.AlignHCenter
              width: Style.space(84)
              foreground: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onEditingFinished: root.commitTransition()
              Keys.onReturnPressed: root.commitTransition()
              Keys.onEnterPressed: root.commitTransition()
            }
          }
        }
      }
    }
  }
}
