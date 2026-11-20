import CoreLocation
import Foundation

/// Each request owns a location manager until it has a single answer or is cancelled.
@MainActor final class DevicePersonLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var fix: CheckedContinuation<CLLocation?, Never>?
    private var requested = false

    static func current(askForPermission: Bool) async -> PersonPlace? {
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil else { return nil }
        let request = DevicePersonLocation()
        return await withTaskCancellationHandler {
            await request.place(askForPermission: askForPermission)
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    private func place(askForPermission: Bool) async -> PersonPlace? {
        guard !Task.isCancelled else { return nil }
        let location = await withCheckedContinuation { continuation in
            fix = continuation
            manager.desiredAccuracy = kCLLocationAccuracyReduced
            manager.delegate = self
            if manager.authorizationStatus == .notDetermined {
                if askForPermission {
                    manager.requestWhenInUseAuthorization()
                } else {
                    finish(nil)
                }
            } else {
                locationManagerDidChangeAuthorization(manager)
            }
        }
        guard let location, !Task.isCancelled else { return nil }
        // Round before sending the point to Apple's reverse geocoder. The raw fix stays on the Mac.
        let coordinate = location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let coarse = CLLocation(latitude: (coordinate.latitude * 10).rounded() / 10,
                                longitude: (coordinate.longitude * 10).rounded() / 10)
        guard let result = try? await geocoder.reverseGeocodeLocation(coarse).first,
              let city = result.locality ?? result.subAdministrativeArea, let country = result.country else { return nil }
        return PersonPlace(city: city, region: result.administrativeArea == city ? nil : result.administrativeArea,
                           country: country, source: .device)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard fix != nil, !requested else { return }
            requested = true
            manager.requestLocation()
        case .notDetermined: break
        default: finish(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ location: CLLocation?) {
        fix?.resume(returning: location)
        fix = nil
    }

    private func cancel() {
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
        finish(nil)
    }
}
