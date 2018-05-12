//
//  ViewController.swift
//  Copyright © 2017 Neil Gupta. All rights reserved.
//

import UIKit
import HomeKit
import CocoaMQTT

class ViewController: UIViewController, HMAccessoryDelegate, HMHomeManagerDelegate, HMHomeDelegate, CocoaMQTTDelegate {
    var homeManager: HMHomeManager!
    var knownCharacteristics = [String: HMCharacteristic]()
    let clientID = "homekit-\(UIDevice.current.identifierForVendor!.uuidString)"
    var mqtt: CocoaMQTT!
    
    override func viewDidLoad() {
        UIApplication.shared.isIdleTimerDisabled = true
        
        mqtt = CocoaMQTT(clientID: clientID, host: "raspberrypi.local", port: 1883)
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
        mqtt.subscribe("hiome/command/#")
        mqtt.subscribe("hiome/announce/#")
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
        let characteristic_value = parts[3]
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
                self.alert(characteristic_id, withError: "failed to set to \(value): \(err?.localizedDescription ?? "unknown")", atLevel: "warning")
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
        // TODO: need some way of linking this device to a specific home location
        // so that it only listens to events for the correct home. Currently,
        // this will only listen to events from the primary home.
        // It will also crash if no primary home is setup.
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
        dataSync("deleted", forObject: didRemove)
    }
    func home(_ home: HMHome, didUpdateNameFor: HMRoom) {
        dataSync("name-changed", forObject: didUpdateNameFor)
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
            if inferEventCategory(service) == "effector" {
                for c in service.characteristics {
                    if c.characteristicType == HMCharacteristicTypePowerState {
                        accessory.delegate = self
                        knownCharacteristics[sanitizeName(service.name)] = c
                        c.readValue { (e) in
                            self.publish(c, accessory: accessory, service: service)
                        }
                        return
                    }
                }
            }
        }
    }
    func deleteAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            if inferEventType(service) != "unknown" {
                dataSync("deleted", forObject: service)
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
        case HMServiceTypeOccupancySensor:
            return "occupancy"
        default:
            return "unknown"
        }
    }
    
    func inferEventCategory(_ service: HMService) -> String {
        if service.serviceType == HMServiceTypeLightbulb || service.associatedServiceType == HMServiceTypeLightbulb {
            return "effector"
        }

        return "sensor"
    }
    
    func sanitizeName(_ name: String) -> String {
        return name.replacingOccurrences(of: ",", with: "")
    }
    
    /** Publishing **/
    
    func alert(_ device: String, withError: String, atLevel: String) {
        mqtt.publish("hiome/alert/homekit", withString: "\(sanitizeName(device)),\(sanitizeName(withError)),\(atLevel),\(NSDate().timeIntervalSince1970)")
    }
    func publishRoom(_ room: HMRoom) {
        mqtt.publish("hiome/room/homekit", withString: "\(sanitizeName(room.name)),null,room,null,\(NSDate().timeIntervalSince1970),\(room.uniqueIdentifier.uuidString)")
    }
    func dataSync(_ action: String, forObject: AnyObject) {
        let ofType = forObject is HMRoom ? "room" : inferEventCategory(forObject as! HMService)
        mqtt.publish("hiome/data-sync/homekit", withString: "\(action),\(ofType),\(sanitizeName(forObject.name)),\(forObject.uniqueIdentifier.uuidString)")
    }
    
    func publish(_ characteristic: HMCharacteristic, accessory: HMAccessory, service: HMService) {
        if characteristic.value == nil {
            return
        }
        
        var val:Int = -1
        switch characteristic.characteristicType {
        case HMCharacteristicTypeBrightness:
            val = (characteristic.value as! Int) > 0 ? 1 : 0
        case HMCharacteristicTypePowerState:
            val = (characteristic.value as! Bool) ? 1 : 0
        default:
            return
        }
        
        // publish string in format "device_id,room_id,type,value,timestamp,characteristic_id"
        mqtt.publish("hiome/\(inferEventCategory(service))/homekit", withString: "\(sanitizeName(service.name)),\(sanitizeName(accessory.room?.name ?? "unknown")),\(inferEventType(service)),\(val),\(NSDate().timeIntervalSince1970),\(characteristic.uniqueIdentifier.uuidString)")
    }
}
