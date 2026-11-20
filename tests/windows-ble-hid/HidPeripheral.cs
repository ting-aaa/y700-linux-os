using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

// A fixed test report map. The keyboard advertises just F15, and the mouse
// advertises a left button (always released) and two relative axes.
public sealed class HidPeripheral
{
    private GattServiceProvider provider;
    private GattLocalCharacteristic keyboard;
    private GattLocalCharacteristic mouse;
    private BluetoothLEAdvertisementPublisher controlPublisher;
    private volatile string advertisementError = "No status event";

    private static readonly byte[] mouseStep = {0, 1, 0xff};
    private static readonly byte[] reportMap = {
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x09, 0x6a, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0x75, 0x07,
        0x95, 0x01, 0x81, 0x03, 0xc0,
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x02,
        0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x09, 0x01,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
        0x81, 0x02, 0x75, 0x07, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
        0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02,
        0x81, 0x06, 0xc0, 0xc0
    };

    private static Guid Uuid(int id)
    {
        return new Guid(string.Format("0000{0:x4}-0000-1000-8000-00805f9b34fb", id));
    }

    private static IBuffer Buffer(byte[] bytes)
    {
        using (var writer = new DataWriter()) {
            writer.WriteBytes(bytes);
            return writer.DetachBuffer();
        }
    }

    private async Task<GattLocalCharacteristic> Add(int id, GattCharacteristicProperties properties, byte[] value)
    {
        var parameters = new GattLocalCharacteristicParameters {
            CharacteristicProperties = properties,
            ReadProtectionLevel = GattProtectionLevel.EncryptionRequired,
            WriteProtectionLevel = GattProtectionLevel.EncryptionRequired
        };
        if (value != null)
            parameters.StaticValue = Buffer(value);
        var result = await provider.Service.CreateCharacteristicAsync(Uuid(id), parameters);
        if (result.Error != BluetoothError.Success)
            throw new InvalidOperationException(string.Format("Characteristic 0x{0:x4}: {1}", id, result.Error));
        return result.Characteristic;
    }

    private async Task<GattLocalCharacteristic> AddInput(byte id, int length)
    {
        var report = await Add(0x2a4d, GattCharacteristicProperties.Read | GattCharacteristicProperties.Notify, new byte[length]);
        var parameters = new GattLocalDescriptorParameters {
            ReadProtectionLevel = GattProtectionLevel.EncryptionRequired,
            StaticValue = Buffer(new byte[] {id, 1})
        };
        var result = await report.CreateDescriptorAsync(Uuid(0x2908), parameters);
        if (result.Error != BluetoothError.Success)
            throw new InvalidOperationException("Report Reference 0x2908: " + result.Error);
        return report;
    }

    public async Task Prepare()
    {
        await CreateService(Uuid(0x1812));
        await Add(0x2a4a, GattCharacteristicProperties.Read, new byte[] {0x11, 0x01, 0, 2});
        await Add(0x2a4b, GattCharacteristicProperties.Read, reportMap);
        var control = await Add(0x2a4c, GattCharacteristicProperties.WriteWithoutResponse, null);
        control.WriteRequested += async (sender, args) => {
            var deferral = args.GetDeferral();
            try { await args.GetRequestAsync(); }
            finally { deferral.Complete(); }
        };
        keyboard = await AddInput(1, 1);
        mouse = await AddInput(2, mouseStep.Length);
    }

    private async Task CreateService(Guid service)
    {
        var result = await GattServiceProvider.CreateAsync(service);
        if (result.Error != BluetoothError.Success)
            throw new InvalidOperationException("GATT Service: " + result.Error);
        provider = result.ServiceProvider;
        provider.AdvertisementStatusChanged += (sender, args) => {
            advertisementError = args.Status + "/" + args.Error;
        };
    }

    private static async Task<Dictionary<string, DeviceInformation>> PairedEndpoints()
    {
        string[] selectors = {
            BluetoothLEDevice.GetDeviceSelectorFromPairingState(true),
            BluetoothDevice.GetDeviceSelectorFromPairingState(true)
        };
        const string key = "System.Devices.Aep.DeviceAddress";
        var found = new Dictionary<string, DeviceInformation>(StringComparer.OrdinalIgnoreCase);
        foreach (var selector in selectors) {
            var items = await DeviceInformation.FindAllAsync(selector, new string[] {key}, DeviceInformationKind.AssociationEndpoint);
            foreach (var item in items) {
                object value;
                if (!item.Properties.TryGetValue(key, out value) || value == null)
                    throw new InvalidOperationException("Paired peer has no address to check");
                found[item.Id] = item;
            }
        }
        return found;
    }

    private static string Address(DeviceInformation item)
    {
        return item.Properties["System.Devices.Aep.DeviceAddress"].ToString().Replace(":", "").Replace("-", "");
    }

    public static async Task<bool> IsTabletPaired(string expectedAddress)
    {
        return (await PairedEndpoints()).Values.Any(item =>
            string.Equals(Address(item), expectedAddress, StringComparison.OrdinalIgnoreCase));
    }

    public static async Task<string[]> BondInventory()
    {
        return (await PairedEndpoints()).Keys.OrderBy(id => id, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public static async Task RestoreTemporaryBond(string expectedAddress, string[] initial, bool requestIssued)
    {
        var original = new HashSet<string>(initial, StringComparer.OrdinalIgnoreCase);
        foreach (var item in (await PairedEndpoints()).Values) {
            if (!requestIssued || original.Contains(item.Id) ||
                !string.Equals(Address(item), expectedAddress, StringComparison.OrdinalIgnoreCase))
                continue;
            var result = await item.Pairing.UnpairAsync();
            if (result.Status != DeviceUnpairingResultStatus.Unpaired && result.Status != DeviceUnpairingResultStatus.AlreadyUnpaired)
                throw new InvalidOperationException("Temporary endpoint unpair: " + result.Status);
        }
        if (!original.SetEquals((await PairedEndpoints()).Keys))
            throw new InvalidOperationException("Host bond inventory differs from its baseline");
    }

    private static async Task<GattSubscribedClient> VerifiedClient(GattLocalCharacteristic report, string tablet)
    {
        var subscribers = report.SubscribedClients;
        if (subscribers.Count != 1) throw new InvalidOperationException("Expected one HID subscriber");
        var client = subscribers[0];
        using (var device = await BluetoothLEDevice.FromIdAsync(client.Session.DeviceId.Id)) {
            if (device == null || !device.DeviceInformation.Pairing.IsPaired ||
                !string.Equals(device.BluetoothAddress.ToString("X12"), tablet, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("HID subscriber does not match the bonded tablet");
        }
        return client;
    }

    private static async Task Send(GattLocalCharacteristic report, GattSubscribedClient client, byte[] value)
    {
        var result = await report.NotifyValueAsync(Buffer(value), client);
        if (result.Status != GattCommunicationStatus.Success)
            throw new InvalidOperationException("HID test notification: " + result.Status);
    }

    // Called only after the tablet exclusively grabbed its two test inputs.
    // There is no user-controlled keycode, mouse button or report payload.
    public async Task SendFixedSample(string tablet)
    {
        var keyClient = await VerifiedClient(keyboard, tablet);
        var mouseClient = await VerifiedClient(mouse, tablet);
        await Send(keyboard, keyClient, new byte[] {1});
        await Send(keyboard, keyClient, new byte[] {0});
        await Send(mouse, mouseClient, mouseStep);
    }
    public static async Task<string> AdapterAddress()
    {
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter == null)
            throw new InvalidOperationException("No host Bluetooth adapter");
        return adapter.BluetoothAddress.ToString("X12");
    }

    public void Advertise(byte[] token)
    {
        var parameters = new GattServiceProviderAdvertisingParameters {
            IsDiscoverable = true, IsConnectable = true
        };
        if (token != null && token.Length > 0)
            parameters.ServiceData = Buffer(token);
        provider.StartAdvertising(parameters);
    }

    public void AdvertiseControl(Guid freshMarker)
    {
        controlPublisher = new BluetoothLEAdvertisementPublisher();
        controlPublisher.Advertisement.ManufacturerData.Add(
            new BluetoothLEManufacturerData(0xffff, Buffer(freshMarker.ToByteArray())));
        controlPublisher.Start();
    }

    public string Status() {
        return controlPublisher == null ? provider.AdvertisementStatus.ToString() : controlPublisher.Status.ToString();
    }
    public string AdvertisementError() { return advertisementError; }
    public void Stop() {
        if (controlPublisher != null) controlPublisher.Stop();
        else provider.StopAdvertising();
    }
}
