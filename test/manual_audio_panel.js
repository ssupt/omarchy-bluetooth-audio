// Run the real Panel click handler with a captured, service-owned request.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')

const panel = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8')
const match = panel.match(/^  function useDeviceForAudio\([^]*?^  \}/m)
assert(match, 'Panel.useDeviceForAudio is missing')

function click(source) {
  const calls = []
  const context = {
    audioProfileChangeBusy: false, deviceActionBusy: false,
    devicePropertyBusy: false, manualAudioBusy: false,
    pendingAction: () => '', audioControlDefaultBridgeReady: true,
    defaultAudioSink: { name: 'old-output' },
    defaultAudioSource: { name: 'old-input' },
    bluetoothAudioSink: () => ({ id: 12, name: 'bluez_output.test' }),
    bluetoothAudioSource: () => source,
    bluetoothService: {
      selectDeviceAudio(address, output, input) {
        calls.push({ address, output, input })
      }
    },
    setDefaultAudioSink: () => assert.fail('Manual output bypassed the service'),
    setDefaultAudioSource: () => assert.fail('Manual input bypassed the service'),
    audioProfileSetError: 'old error'
  }
  vm.createContext(context)
  vm.runInContext(match[0] + '\nuseDeviceForAudio({address:"00:11:22:33:44:55"});', context)
  return { calls, context }
}

let result = click({ id: 13, name: 'bluez_input.test' })
assert.equal(result.calls.length, 1)
assert.equal(result.calls[0].address, '00:11:22:33:44:55')
assert.equal(result.calls[0].output.name, 'bluez_output.test')
assert.equal(result.calls[0].output.previous, 'old-output')
assert.equal(result.calls[0].input.name, 'bluez_input.test')
assert.equal(result.calls[0].input.previous, 'old-input')
assert.equal(result.context.audioProfileSetError, '')

result = click(null)
assert.equal(result.calls.length, 1)
assert.equal(result.calls[0].input, null)

console.log('PASS: manual Use for audio routes captured defaults through the shared service')
