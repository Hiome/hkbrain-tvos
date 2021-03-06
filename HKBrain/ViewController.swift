//
//  ViewController.swift
//  Copyright © 2017 Neil Gupta. All rights reserved.
//

import UIKit
import HomeKit
import CocoaMQTT
import Sentry

class ViewController: UIViewController, HMAccessoryDelegate, HMHomeManagerDelegate, HMHomeDelegate, CocoaMQTTDelegate {
    var homeManager: HMHomeManager!
    var knownCharacteristics = [String: HMCharacteristic]()
    let clientID = "homekit-\(UIDevice.current.identifierForVendor!.uuidString)"
    var mqtt: CocoaMQTT!
    
    override func viewDidLoad() {
        UIApplication.shared.isIdleTimerDisabled = true
        
        mqtt = CocoaMQTT(clientID: clientID, host: "hiomehub.local", port: 1883)
        let will = CocoaMQTTWill(topic: "hiome/lifecycle/homekit/\(clientID)", message: "disconnected")
        will.retained = true
        mqtt.willMessage = will
        mqtt.cleanSession = false
        mqtt.keepAlive = 60
        mqtt.delegate = self
        mqtt.connect()
        
        homeManager = HMHomeManager()
        homeManager.delegate = self
        super.viewDidLoad()
    }
    
    /** MQTT Delegate **/

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        mqtt.publish("hiome/lifecycle/homekit/\(clientID)", withString: "connected", retained: true)
        mqtt.subscribe("hiome/command/#", qos: CocoaMQTTQOS.qos1)
        mqtt.subscribe("hiome/announce/#")
        if homeManager.primaryHome != nil {
            refreshHome(homeManager.primaryHome!)
        }
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16 ) {
        if message.topic.starts(with: "hiome/announce") {
            if message.string == "refresh" {
                refreshHome(homeManager.primaryHome!)
            }
            return
        }
        
        let parts = message.string!.components(separatedBy: ",")
        let characteristic_id = parts[0]
        let characteristic_value = parts[2]
        let charactertistic = knownCharacteristics[characteristic_id]
        if charactertistic == nil {
            print("could not find device \(characteristic_id)")
            return
        }
        
        let value = characteristic_value == "1"
        print("received \(message.string!) for \(characteristic_id) to set \(value)")
        knownCharacteristics[characteristic_id]?.writeValue(value, completionHandler: { (err) in
            if err == nil {
                print("success!")
            } else {
                print("FAILED ##############")
                print(err?.localizedDescription ?? "unknown")
                self.alert(characteristic_id, withError: "failed to set to \(value): \(err?.localizedDescription ?? "unknown")", atLevel: "error")
            }
        })
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopic topic: String) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopic topic: String) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        // try to reconnect
        mqtt.connect()
    }
    
    /** HMHomeManager Delegate **/
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        refreshHome(manager.primaryHome!)
    }
    func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager) {
        refreshHome(manager.primaryHome!)
    }
    
    /** HMHome Delegate **/
    
    func home(_ home: HMHome, didAdd: HMAccessory) {
        refreshAccessory(didAdd)
    }
    func home(_ home: HMHome, didRemove: HMAccessory) {
        deleteAccessory(didRemove)
    }
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        deleteAccessory(accessory)
        refreshAccessory(accessory)
    }
    func home(_ home: HMHome, didAdd: HMRoom) {
        publishRoom(didAdd)
    }
    func home(_ home: HMHome, didRemove: HMRoom) {
        deleteRoom(didRemove)
    }
    func home(_ home: HMHome, didUpdateNameFor: HMRoom) {
        publishRoom(didUpdateNameFor)
    }
    
    /** HMAccessory Delegate **/
    
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        refreshAccessory(accessory)
    }
    func accessory(_ accessory: HMAccessory, didUpdateAssociatedServiceTypeFor: HMService) {
        refreshAccessory(accessory)
    }
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        refreshAccessory(accessory)
    }
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        publish(characteristic, accessory: accessory, service: service)
    }
    
    /** Helpers **/
    
    func refreshHome(_ primaryHome: HMHome) {
        primaryHome.delegate = self
        for a in primaryHome.accessories {
            refreshAccessory(a)
        }
        for r in primaryHome.rooms {
            publishRoom(r)
        }
    }
    
    func refreshAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            let type = inferEventType(service)
            if type != "" {
                for c in service.characteristics {
                    if (type == "light" && c.characteristicType == HMCharacteristicTypePowerState) ||
                        (type == "motion" && c.characteristicType == HMCharacteristicTypeMotionDetected) {
                        accessory.delegate = self
                        knownCharacteristics[service.uniqueIdentifier.uuidString] = c
                        c.readValue { (e) in
                            if e != nil {
                                self.alert(service.uniqueIdentifier.uuidString, withError: "failed to read \(service.name): \(e!.localizedDescription)", atLevel: "error")
                            }
                            self.publish(c, accessory: accessory, service: service, refresh: true)
                        }
                        c.enableNotification(true) { (e) in
                            if e != nil {
                                self.alert(service.uniqueIdentifier.uuidString, withError: "failed to enable notifications for \(service.name): \(e!.localizedDescription)", atLevel: "error")
                            }
                        }
                    }
                }
            }
        }
    }
    
    func deleteAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            if inferEventType(service) != "" {
                deleteService(service)
                return
            }
        }
    }
    
    func inferEventType(_ service: HMService) -> String {
        switch service.associatedServiceType ?? service.serviceType {
        case HMServiceTypeLightbulb:
            return "light"
        case HMServiceTypeMotionSensor:
            return "motion"
        default:
            return ""
        }
    }
    
    func inferEventCategory(_ service: HMService) -> String {
        if service.serviceType == HMServiceTypeLightbulb || service.associatedServiceType == HMServiceTypeLightbulb {
            return "effector"
        }

        return "sensor"
    }
    
    func safeStr(_ name: String) -> String {
        return name.replacingOccurrences(of: ",", with: "")
    }
    
    /** Publishing **/
    
    func alert(_ device: String, withError: String, atLevel: String) {
        mqtt.publish("hiome/alert/homekit", withString: "\(device),\(safeStr(withError)),\(atLevel)")
        if atLevel == "error" {
            let event = Event(level: .error)
            event.message = withError
            event.extra = ["device": device]
            Client.shared?.send(event: event) { (error) in
                if error != nil {
                    self.mqtt.publish("hiome/alert/homekit", withString: "sentry,\(self.safeStr(error!.localizedDescription)),error")
                }
            }
        }
    }
    func publishRoom(_ room: HMRoom) {
        mqtt.publish("hiome/room/homekit", withString: "\(room.uniqueIdentifier.uuidString),\(safeStr(room.name))", qos: CocoaMQTTQOS.qos1)
    }
    func deleteRoom(_ room: HMRoom) {
        mqtt.publish("hiome/room/homekit", withString: "\(room.uniqueIdentifier.uuidString),#DELETED#", qos: CocoaMQTTQOS.qos1)
    }
    func deleteService(_ service: HMService) {
        mqtt.publish("hiome/\(inferEventCategory(service))/homekit", withString: "\(service.uniqueIdentifier.uuidString),#DELETED#", qos: CocoaMQTTQOS.qos1)
    }
    func publishBrightnessAsPowerState(accessory: HMAccessory, service: HMService, refresh: Bool = false) {
        let c = knownCharacteristics[service.uniqueIdentifier.uuidString]
        if c == nil {
            print("could not find device \(service.uniqueIdentifier.uuidString)")
            return
        }
        c!.readValue { (e) in
            if e != nil {
                self.alert(service.uniqueIdentifier.uuidString, withError: "failed to read \(service.name): \(e!.localizedDescription)", atLevel: "error")
            }
            self.publish(c!, accessory: accessory, service: service, refresh: refresh)
        }
    }
    func publish(_ characteristic: HMCharacteristic, accessory: HMAccessory, service: HMService, refresh: Bool = false) {
        if characteristic.value == nil {
            return
        }
        
        var val:Int = -1
        switch characteristic.characteristicType {
        case HMCharacteristicTypeBrightness:
            return publishBrightnessAsPowerState(accessory: accessory, service: service, refresh: refresh)
        case HMCharacteristicTypePowerState, HMCharacteristicTypeMotionDetected:
            val = (characteristic.value as! Bool) ? 1 : 0
        default:
            print("trying to publish unknown characteristic type for \(service.name)")
            return
        }
        
        let ts = refresh ? ",refresh" : ""
        // publish string in format "device_id,room_id,value,name,type,refresh"
        mqtt.publish("hiome/\(inferEventCategory(service))/homekit", withString: "\(service.uniqueIdentifier.uuidString),\(accessory.room?.uniqueIdentifier.uuidString ?? ""),\(val),\(safeStr(service.name)),\(inferEventType(service))\(ts)",
            qos: CocoaMQTTQOS.qos1)
    }
}
