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
    
    let clientID = UIDevice.current.identifierForVendor!.uuidString
    var mqtt: CocoaMQTT!
    
    override func viewDidLoad() {
        UIApplication.shared.isIdleTimerDisabled = true
        
        mqtt = CocoaMQTT(clientID: clientID, host: "raspberrypi.local", port: 1883)
        mqtt.willMessage = CocoaMQTTWill(topic: "smarter/homekit/lifecycle/" + clientID, message: "disconnected")
        mqtt.keepAlive = 60
        mqtt.delegate = self
        mqtt.connect()
        
        homeManager.delegate = self
        super.viewDidLoad()
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        mqtt.publish("smarter/homekit/lifecycle/" + clientID, withString: "connected")
        mqtt.subscribe("smarter/homekit/instructions/#")
    }
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16 ) {
        if message.string == "refresh" {
            for a in home.accessories {
                refreshAccessory(a)
            }
            return
        }
        
        let parts = message.string!.components(separatedBy: ",")
        let characteristic_id = parts[0]
        let characteristic_value = parts[4]
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
                mqtt.publish("smarter/homekit/success/\(self.clientID)", withString: "\(characteristic_id),\(value),success,\(NSDate().timeIntervalSince1970)")
            } else {
                print("FAILED ##############")
                print(err?.localizedDescription ?? "unknown")
                mqtt.publish("smarter/homekit/errors/\(self.clientID)", withString: "\(characteristic_id),\(value),\(err?.localizedDescription ?? "unknown"),\(NSDate().timeIntervalSince1970)")
            }
        })
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        
    }
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopic topic: String) {
        
    }
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopic topic: String) {
        
    }
    func mqttDidPing(_ mqtt: CocoaMQTT) {
        
    }
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        
    }
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        // try to reconnect
        mqtt.connect()
    }
    
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
    func refreshHome(_ primaryHome: HMHome) {
        home = primaryHome
        home.delegate = self
        for a in home.accessories {
            refreshAccessory(a)
        }
    }
    
    func home(_ home: HMHome, didAdd: HMAccessory) {
        refreshAccessory(didAdd)
    }
    
    func home(_ home: HMHome, didRemove: HMAccessory) {
        deleteAccessory(didRemove)
    }
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        deleteAccessory(accessory)
    }
    func deleteAccessory(_ accessory: HMAccessory) {
        mqtt.publish("smarter/homekit/data/\(clientID)", withString: "\(accessory.uniqueIdentifier.uuidString),deleted")
    }
    
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        refreshAccessory(accessory)
    }
    
    func accessory(_ accessory: HMAccessory, didUpdateAssociatedServiceTypeFor: HMService) {
        refreshAccessory(accessory)
    }
    
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        refreshAccessory(accessory)
    }
    
    func refreshAccessory(_ accessory: HMAccessory) {
        for service in accessory.services {
            // only subscribe to lights and TV power state
            if service.serviceType == HMServiceTypeLightbulb || service.associatedServiceType == HMServiceTypeLightbulb {
                for c in service.characteristics {
                    if c.characteristicType == HMCharacteristicTypePowerState {
                        c.enableNotification(true, completionHandler: { (error) in
                            if error != nil {
                                print("ENABLING NOTIFICATION FOR \(service.name) FAILED ##############")
                                print(error?.localizedDescription ?? "unknown")
                                self.mqtt.publish("smarter/homekit/errors/\(self.clientID)", withString: "\(self.sanitizeName(service.name)),\(error?.localizedDescription ?? "unknown"),\(NSDate().timeIntervalSince1970)")
                            } else {
                                print("enabled notifications for \(self.sanitizeName(service.name)) of type \(c.localizedDescription)")
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
    
    func inferEventType(_ service: HMService) -> String {
        if service.serviceType == HMServiceTypeLightbulb || service.associatedServiceType == HMServiceTypeLightbulb {
            return "light"
        }
        
        return "sensor"
    }
    
    func sanitizeName(_ name: String) -> String {
        return name.replacingOccurrences(of: ",", with: "")
    }
    
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        publish(characteristic, accessory: accessory, service: service)
    }
    
    func publish(_ characteristic: HMCharacteristic, accessory: HMAccessory, service: HMService) {
        // Harmony Hub somehow keeps emitting its own custom property despite us never subscribing for it, so filter for power state characteristic only
        if characteristic.characteristicType == HMCharacteristicTypePowerState {
            // publish string in format "device_id,room_id,type,source,value,timestamp,characteristic_id"
            mqtt.publish("smarter/homekit/data/\(clientID)", withString: "\(sanitizeName(service.name)),\(sanitizeName(accessory.room?.name ?? "unknown")),\(inferEventType(service)),homekit,\(characteristic.value ?? "unknown"),\(NSDate().timeIntervalSince1970),\(characteristic.uniqueIdentifier.uuidString)")
        }
    }
}

