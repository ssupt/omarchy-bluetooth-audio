// Exercise the real mouse/keyboard connection handlers while another device is busy.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')

const panel = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8')
const methods = ['runDeviceAction', 'connectDevice', 'disconnectDevice', 'cancelDeviceConnection']
  .map(name => {
    const match = panel.match(new RegExp('^  function ' + name + '\\([^]*?^  \\}', 'm'))
    assert(match, 'Missing connection handler: ' + name)
    return match[0]
  }).join('\n')
const calls = []
const context = {
  devicePropertyBusy: false, audioProfileChangeBusy: false, deviceActionBusy: true,
  bluetoothService: {
    ready: true, activeConnection: { action: 'connect', address: '00:11:22:33:44:55' },
    chooseDeviceConnection(action, address, devicePath) { calls.push({ action, address, devicePath }) },
    cancelDeviceAction(address) { calls.push({ cancel: address }); return true }
  },
  setDeviceActionFailure() {},
  pendingAction() { return '' }
}
vm.createContext(context)
vm.runInContext(methods, context)
const target = { address: '11:22:33:44:55:66', paired: true, connected: false,
  dbusPath: '/org/bluez/hci1/dev_11_22_33_44_55_66' }

context.connectDevice(target)
assert.deepEqual(calls.pop(), { action: 'connect', address: target.address, devicePath: target.dbusPath })
context.connectDevice({ ...target, paired: false })
assert.equal(calls.pop().action, 'pair')
context.bluetoothService.ready = false
context.connectDevice(target)
assert.equal(calls.pop().address, target.address)
context.disconnectDevice({ ...target, connected: true })
assert.equal(calls.pop().cancel, target.address)
context.cancelDeviceConnection(target)
assert.equal(calls.pop().cancel, target.address)

context.devicePropertyBusy = true
context.connectDevice(target)
context.devicePropertyBusy = false
context.audioProfileChangeBusy = true
context.connectDevice(target)
context.audioProfileChangeBusy = false
context.bluetoothService.activeConnection = null
context.connectDevice(target)
assert.equal(calls.length, 0, 'Connection selection interrupted an unrelated mutation')
console.log('PASS: panel connection clicks replace pending choices and preserve unrelated operation guards')
