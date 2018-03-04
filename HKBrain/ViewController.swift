//
//  ViewController.swift
//  Copyright © 2017 Neil Gupta. All rights reserved.
//

import UIKit
import HomeKit
import CocoaMQTT

class ViewController: UIViewController, HMAccessoryDelegate, HMHomeManagerDelegate, HMHomeDelegate, CocoaMQTTDelegate {
    let homeManager = HMHomeManager()
    var home: HMHome!
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
                refreshHome(home)
            }
            return
        }
        
        let parts = message.string!.components(separatedBy: ",")
        let characteristic_id = parts[0]
        let characteristic_value = parts[3]
        let charactertistic = knownCharacteristics[characteristic_id]
        if charactertistic == nil {
            print("could not find device \(characteristic_id)")
            alert(characteristic_id, withError: "device not found", atLevel: "warning")
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
        // Harmony Hub somehow keeps emitting its own custom property despite us never subscribing for it, so filter for power state characteristic only
        if characteristic.characteristicType == HMCharacteristicTypePowerState {
            publish(characteristic, accessory: accessory, service: service)
        }
    }
    
    /** Helpers **/
    
    func refreshHome(_ primaryHome: HMHome) {
        home = primaryHome
        home.delegate = self
        for a in home.accessories {
            refreshAccessory(a)
        }
        for r in home.rooms {
            publishRoom(r)
        }
    }
    
    func refreshAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            if inferEventCategory(service) == "effector" {
                for c in service.characteristics {
                    if c.characteristicType == HMCharacteristicTypePowerState {
                        c.enableNotification(true, completionHandler: { (error) in
                            if error != nil {
                                print("ENABLING NOTIFICATION FOR \(service.name) FAILED ##############")
                                print(error?.localizedDescription ?? "unknown")
                                self.alert(service.name, withError: "failed to enable notifications because: \(error?.localizedDescription ?? "unknown")", atLevel: "warning")
                            } else {
                                print("enabled notifications for \(service.name) of type \(c.localizedDescription)")
                            }
                        })
                        knownCharacteristics[sanitizeName(service.name)] = c
                        publish(c, accessory: accessory, service: service)
                    }
                }
            }
        }
        accessory.delegate = self
    }
    func deleteAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            if inferEventType(service) != "unknown" {
                dataSync("deleted", forObject: service)
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
        // publish string in format "device_id,room_id,type,value,timestamp,characteristic_id"
        mqtt.publish("hiome/\(inferEventCategory(service))/homekit", withString: "\(sanitizeName(service.name)),\(sanitizeName(accessory.room?.name ?? "unknown")),\(inferEventType(service)),\(characteristic.value ?? "unknown"),\(NSDate().timeIntervalSince1970),\(characteristic.uniqueIdentifier.uuidString)")
    }
}
