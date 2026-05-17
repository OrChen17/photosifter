import XCTest
@testable import PhotoSifter

final class AppSettingsTests: XCTestCase {
    // Keep in sync with AppSettings.cloudKey
    private let cloudKey = "allowCloudDownload"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: cloudKey)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: cloudKey)
    }

    // MARK: - Static accessor

    func testCloudDownloadEnabled_static_defaultsTrueWhenKeyAbsent() {
        // No value written — must behave as if true
        XCTAssertTrue(AppSettings.cloudDownloadEnabled, "Absent key should default to true")
    }

    func testCloudDownloadEnabled_static_returnsTrueWhenStoredTrue() {
        UserDefaults.standard.set(true, forKey: cloudKey)
        XCTAssertTrue(AppSettings.cloudDownloadEnabled)
    }

    func testCloudDownloadEnabled_static_returnsFalseWhenStoredFalse() {
        UserDefaults.standard.set(false, forKey: cloudKey)
        XCTAssertFalse(AppSettings.cloudDownloadEnabled,
                       "Stored false must not be silently promoted to the default-true path")
    }

    // MARK: - Instance

    func testAllowCloudDownload_instance_defaultsTrueWhenKeyAbsent() {
        let settings = AppSettings()
        XCTAssertTrue(settings.allowCloudDownload, "Instance default must be true when key is absent")
    }

    func testAllowCloudDownload_instance_readsStoredTrue() {
        UserDefaults.standard.set(true, forKey: cloudKey)
        XCTAssertTrue(AppSettings().allowCloudDownload)
    }

    func testAllowCloudDownload_instance_readsStoredFalse() {
        UserDefaults.standard.set(false, forKey: cloudKey)
        XCTAssertFalse(AppSettings().allowCloudDownload)
    }

    func testAllowCloudDownload_instance_persistsOnChange() {
        let settings = AppSettings()
        settings.allowCloudDownload = false

        // Static accessor reflects the new value immediately (same UserDefaults.standard)
        XCTAssertFalse(AppSettings.cloudDownloadEnabled)
    }

    // MARK: - Static/instance consistency

    func testStaticAndInstance_agreeOnStoredValue() {
        UserDefaults.standard.set(false, forKey: cloudKey)
        let instance = AppSettings()
        XCTAssertEqual(AppSettings.cloudDownloadEnabled, instance.allowCloudDownload,
                       "Static and instance accessors must return the same value")
    }
}
