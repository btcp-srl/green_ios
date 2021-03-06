import UIKit
import PromiseKit
import RxSwift
import RxBluetoothKit

class HardwareWalletScanViewController: UIViewController {

    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var radarImageView: RadarImageView!

    let timeout = RxTimeInterval.seconds(10)
    var peripherals = [ScannedPeripheral]()

    var scanningDispose: Disposable?
    var enstablishDispose: Disposable?

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tableFooterView = UIView()

        let manager = AppDelegate.manager
        switch manager.state {
        case .poweredOn:
            scanningDispose = scan()
            return
        case .poweredOff:
            showError(NSLocalizedString("id_turn_on_bluetooth_to_connect", comment: ""))
        default:
            break
        }

        // wait bluetooth is ready
        scanningDispose = manager.observeState()
            .filter { $0 == .poweredOn }
            .take(1)
            .subscribe(onNext: { _ in
                self.scanningDispose = self.scan()
            }, onError: { err in
                self.showError(err.localizedDescription)
            })
    }

    func scan() -> Disposable {
        return AppDelegate.manager.scanForPeripherals(withServices: nil)
            .filter { $0.peripheral.name?.contains("Nano") ?? false }
            .subscribe(onNext: { p in
                self.peripherals.removeAll { $0.rssi == p.rssi }
                self.peripherals.append(p)
                self.tableView.reloadData()
            }, onError: { err in
                self.showError(err.localizedDescription)
            })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        radarImageView.startSpinning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        scanningDispose?.dispose()
        AppDelegate.manager.manager.stopScan()
    }
}

extension HardwareWalletScanViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return peripherals.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: "HardwareDeviceCell",
                                                    for: indexPath as IndexPath) as? HardwareDeviceCell {
            let p = peripherals[indexPath.row]
            cell.nameLabel.text = p.advertisementData.localName
            cell.connectionStatusLabel.text = p.peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: "paired_device_uuid") ? "Current selected" : ""
            cell.accessoryType = p.advertisementData.isConnectable ?? false ? .disclosureIndicator : .none
            return cell
        }
        return UITableViewCell()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let peripheral = peripherals[indexPath.row].peripheral
        scanningDispose?.dispose()
        enstablishDispose?.dispose()
        self.connect(peripheral: peripheral)
    }
}

extension HardwareWalletScanViewController {

    enum DeviceError: Error {
        case dashboard
        case wrong_app
    }

    func network() -> String {
        return getGdkNetwork(getNetwork()).network.lowercased() == "testnet" ? "Bitcoin Test" : "Bitcoin"
    }

    func connect(peripheral: Peripheral) {
        startAnimating()
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let session = getGAService().getSession()

        enstablishDispose = peripheral.establishConnection()
            .observeOn(SerialDispatchQueueScheduler(qos: .background))
            .flatMap { Ledger.shared.open($0) }
            .observeOn(SerialDispatchQueueScheduler(qos: .background))
            .flatMap { _ in Ledger.shared.application() }
            .compactMap { res in
                let name = res["name"] as? String ?? ""
                if name.contains("OLOS") {
                    throw DeviceError.dashboard // open app from dashboard
                } else if name != self.network() {
                    throw DeviceError.wrong_app // change app
                }
            }.observeOn(SerialDispatchQueueScheduler(qos: .background))
            .compactMap { _ in
                appDelegate?.disconnect()
                try appDelegate?.connect()
                _ = try session.registerUser(mnemonic: "", hw_device: ["device": (Ledger.shared.hwDevice as Any) ]).resolve().wait()
                _ = try session.login(mnemonic: "", hw_device: ["device": Ledger.shared.hwDevice]).resolve().wait()
            }.observeOn(MainScheduler.instance)
            .subscribe(onNext: { _ in
                self.stopAnimating()
                getAppDelegate()!.instantiateViewControllerAsRoot(storyboard: "Wallet", identifier: "TabViewController")
            }, onError: { err in
                self.stopAnimating()
                switch err {
                case is BluetoothError:
                    let bleErr = err as? BluetoothError
                    self.showError(NSLocalizedString("id_communication_timed_out_make", comment: "") + ": \(bleErr?.localizedDescription ?? "")")
                case RxError.timeout:
                    self.showError(NSLocalizedString("id_communication_timed_out_make", comment: ""))
                case DeviceError.dashboard:
                    self.showError(String(format: NSLocalizedString("id_select_the_s_app_on_your_ledger", comment: ""), self.network()))
                case DeviceError.wrong_app:
                self.showError(String(format: NSLocalizedString("id_select_the_s_app_on_your_ledger", comment: ""), self.network()))
                case is AuthenticationTypeHandler.AuthError:
                    let authErr = err as? AuthenticationTypeHandler.AuthError
                    self.showError(authErr?.localizedDescription ?? "")
                case is Ledger.SWError:
                    self.showError(NSLocalizedString("id_invalid_status_check_that_your", comment: ""))
                default:
                    self.showError(err.localizedDescription)
                }
            })
    }
}

extension Observable {
    func timeoutIfNoEvent(_ dueTime: RxTimeInterval) -> Observable<Element> {
        let timeout = Observable
            .never()
            .timeout(dueTime, scheduler: MainScheduler.instance)

        return self.amb(timeout)
    }
}
