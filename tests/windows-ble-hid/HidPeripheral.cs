using System;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

// A fixed test report map. The keyboard advertises just F15, and the mouse
// advertises two relative axes. Advertising this profile emits no HID input.
public sealed class HidPeripheral
{
    private GattServiceProvider provider;
    private BluetoothLEAdvertisementPublisher controlPublisher;
    private volatile string advertisementError = "No status event";

    private static readonly byte[] reportMap = {
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x09, 0x6a, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0x75, 0x07,
        0x95, 0x01, 0x81, 0x03, 0xc0,
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x02,
        0x09, 0x01, 0xa1, 0x00, 0x09, 0x30, 0x09, 0x31,
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

    private async Task AddInput(byte id, int length)
    {
        var report = await Add(0x2a4d, GattCharacteristicProperties.Read | GattCharacteristicProperties.Notify, new byte[length]);
        var parameters = new GattLocalDescriptorParameters {
            ReadProtectionLevel = GattProtectionLevel.EncryptionRequired,
            StaticValue = Buffer(new byte[] {id, 1})
        };
        var result = await report.CreateDescriptorAsync(Uuid(0x2908), parameters);
        if (result.Error != BluetoothError.Success)
            throw new InvalidOperationException("Report Reference 0x2908: " + result.Error);
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
        await AddInput(1, 1);
        await AddInput(2, 2);
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

    public static async Task<bool> IsTabletPaired(string expectedAddress)
    {
        string[] selectors = {
            BluetoothLEDevice.GetDeviceSelectorFromPairingState(true),
            BluetoothDevice.GetDeviceSelectorFromPairingState(true)
        };
        const string key = "System.Devices.Aep.DeviceAddress";
        foreach (var selector in selectors) {
            var items = await DeviceInformation.FindAllAsync(selector, new string[] {key}, DeviceInformationKind.AssociationEndpoint);
            foreach (var item in items) {
                object value;
                if (!item.Properties.TryGetValue(key, out value) || value == null)
                    throw new InvalidOperationException("Paired peer has no address to check");
                if (string.Equals(value.ToString().Replace(":", "").Replace("-", ""),
                                  expectedAddress, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        return false;
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
