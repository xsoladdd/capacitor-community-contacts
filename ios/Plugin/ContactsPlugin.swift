import Foundation
import Capacitor
import Contacts
import ContactsUI

enum CallingMethod {
    case GetContact
    case GetContacts
    case CreateContact
    case DeleteContact
    case PickContact
}

@objc(ContactsPlugin)
public class ContactsPlugin: CAPPlugin {
    private let implementation = Contacts()

    private var callingMethod: CallingMethod?

    private var pickContactCallbackId: String?
    private var activeContactPickerDelegate: NSObject?

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let permissionState: String

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            permissionState = "prompt"
        case .restricted, .denied:
            permissionState = "denied"
        case .authorized:
            permissionState = "granted"
        case .limited:
            permissionState = "limited"
        @unknown default:
            permissionState = "prompt"
        }

        call.resolve([
            "contacts": permissionState
        ])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
            self?.checkPermissions(call)
        }
    }

    private func requestContactsPermission(_ call: CAPPluginCall, _ callingMethod: CallingMethod) {
        self.callingMethod = callingMethod
        if isContactsPermissionGranted() {
            permissionCallback(call)
        } else {
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
                self?.permissionCallback(call)
            }
        }
    }

    private func isContactsPermissionGranted() -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined, .restricted, .denied:
            return false
        case .authorized, .limited:
            return true
        @unknown default:
            return false
        }
    }

    private func permissionCallback(_ call: CAPPluginCall) {
        let method = self.callingMethod

        self.callingMethod = nil

        if !isContactsPermissionGranted() {
            call.reject("Permission is required to access contacts.")
            return
        }

        switch method {
        case .GetContact:
            getContact(call)
        case .GetContacts:
            getContacts(call)
        case .CreateContact:
            createContact(call)
        case .DeleteContact:
            deleteContact(call)
        case .PickContact:
            pickContact(call)
        default:
            // No method was being called,
            // so nothing has to be done here.
            break
        }
    }

    @objc func getContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contact = implementation.getContact(contactId, projectionInput)

            guard let contact = contact else {
                call.reject("Contact not found.")
                return
            }

            call.resolve([
                "contact": contact.getJSObject()
            ])
        }
    }

    @objc func getContacts(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContacts)
        } else {
            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contacts = implementation.getContacts(projectionInput)

            var contactsJSArray: JSArray = JSArray()

            for contact in contacts {
                contactsJSArray.append(contact.getJSObject())
            }

            call.resolve([
                "contacts": contactsJSArray
            ])
        }
    }

    @objc func createContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.CreateContact)
        } else {
            let contactInput = CreateContactInput.init(call.getObject("contact", JSObject()))

            let contactId = implementation.createContact(contactInput)

            guard let contactId = contactId else {
                call.reject("Something went wrong.")
                return
            }

            call.resolve([
                "contactId": contactId
            ])
        }
    }

    @objc func deleteContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.DeleteContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            if !implementation.deleteContact(contactId) {
                call.reject("Something went wrong.")
                return
            }

            call.resolve()
        }
    }

    @objc func pickContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.PickContact)
        } else {
            DispatchQueue.main.async {
                self.bridge?.saveCall(call)
                self.pickContactCallbackId = call.callbackId

                let contactPicker = CNContactPickerViewController()
                let delegate = SingleContactPickerDelegate(plugin: self, callbackId: call.callbackId)
                self.activeContactPickerDelegate = delegate
                contactPicker.delegate = delegate

                self.bridge?.viewController?.present(contactPicker, animated: true)
            }
        }
    }

    private class SingleContactPickerDelegate: NSObject, CNContactPickerDelegate {
        private weak var plugin: ContactsPlugin?
        private let callbackId: String

        init(plugin: ContactsPlugin, callbackId: String) {
            self.plugin = plugin
            self.callbackId = callbackId
        }

        public func contactPicker(_ picker: CNContactPickerViewController, didSelect selectedContact: CNContact) {
            picker.dismiss(animated: true)

            guard let plugin = self.plugin else { return }
            guard let call = plugin.bridge?.savedCall(withID: self.callbackId) else { return }

            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())
            if let projected = plugin.implementation.getContact(selectedContact.identifier, projectionInput) {
                call.resolve([
                    "contact": projected.getJSObject()
                ])
            } else {
                let contact = ContactPayload(selectedContact.identifier)
                contact.fillData(selectedContact)
                call.resolve([
                    "contact": contact.getJSObject()
                ])
            }

            plugin.bridge?.releaseCall(call)
            plugin.pickContactCallbackId = nil
            plugin.activeContactPickerDelegate = nil
        }

        public func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            guard let plugin = self.plugin else { return }
            guard let call = plugin.bridge?.savedCall(withID: self.callbackId) else { return }

            call.reject("User cancelled contact selection")
            plugin.bridge?.releaseCall(call)
            plugin.pickContactCallbackId = nil
            plugin.activeContactPickerDelegate = nil
        }
    }

    private class MultiContactPickerDelegate: NSObject, CNContactPickerDelegate {
        private weak var plugin: ContactsPlugin?
        private let callbackId: String

        init(plugin: ContactsPlugin, callbackId: String) {
            self.plugin = plugin
            self.callbackId = callbackId
        }

        public func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            picker.dismiss(animated: true)

            guard let plugin = self.plugin else { return }
            guard let call = plugin.bridge?.savedCall(withID: self.callbackId) else { return }

            var contactsArray: [JSObject] = []
            for selectedContact in contacts {
                let contact = ContactPayload(selectedContact.identifier)
                contact.fillData(selectedContact)
                contactsArray.append(contact.getJSObject())
            }

            call.resolve([
                "contacts": contactsArray
            ])

            plugin.bridge?.releaseCall(call)
            plugin.pickContactCallbackId = nil
            plugin.activeContactPickerDelegate = nil
        }

        public func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            guard let plugin = self.plugin else { return }
            guard let call = plugin.bridge?.savedCall(withID: self.callbackId) else { return }

            call.resolve([
                "contacts": []
            ])
            plugin.bridge?.releaseCall(call)
            plugin.pickContactCallbackId = nil
            plugin.activeContactPickerDelegate = nil
        }
    }

    @objc func requestLimitedContactsAccess(_ call: CAPPluginCall) {
        if #available(iOS 18.0, *) {
            let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

            switch authorizationStatus {
            case .limited, .notDetermined:
                self.presentContactAccessPicker(call)
            case .authorized:
                call.resolve([
                    "contacts": []
                ])
            case .restricted, .denied:
                call.reject("Contact access is denied or restricted.")
            @unknown default:
                call.reject("Unknown authorization status.")
            }
        } else {
            call.reject("Limited contacts access is not supported on this iOS version. iOS 18+ required.")
        }
    }

    @available(iOS 18.0, *)
    private func presentContactAccessPicker(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let contactPicker = CNContactPickerViewController()
            let delegate = MultiContactPickerDelegate(plugin: self, callbackId: call.callbackId)
            self.activeContactPickerDelegate = delegate
            contactPicker.delegate = delegate

            contactPicker.predicateForEnablingContact = NSPredicate(value: true)

            self.bridge?.saveCall(call)
            self.pickContactCallbackId = call.callbackId

            self.bridge?.viewController?.present(contactPicker, animated: true)
        }
    }

    @objc func isLimitedContactsAccessSupported(_ call: CAPPluginCall) {
        if #available(iOS 18.0, *) {
            call.resolve(["supported": true])
        } else {
            call.resolve(["supported": false])
        }
    }
}
