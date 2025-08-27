<template>
  <GenericPageLayout
    title="Paint"
    icon="flipper:paint"
  description="Pixel editor for Kiisu, streamed to the device"
    class="relative-position"
  >
    <div class="column fit">
      <div class="col fit column items-center paint">
        <q-page-sticky position="bottom" :offset="[16, 40]">
          <PaintPixelControls />
        </q-page-sticky>

        <PaintPixelEditor
          class="col"
          @keydown="handleInteraction"
          @mouseup="mouseUp"
          @mousemove="handleInteraction"
        />

        <q-page-sticky position="bottom-right" :offset="[8, 8]">
          <PaintMirror />
        </q-page-sticky>

        <q-dialog v-model="paintStore.flags.ditherDialog">
          <PaintDitherCard
            :img="paintStore.uploadedImage"
            @cancel="paintStore.flags.ditherDialog = false"
            @select="drawImage"
          />
        </q-dialog>
      </div>
    </div>

    <template #info>
      <h6 class="q-mt-none q-mb-sm">About Paint</h6>
      <p>
        Draw pixel art or test UI elements right on your Kiisu's screen. The
        editor is streamed to the device in real-time. Use basic drawing tools,
        upload images and export the Paint canvas to a PNG when you're done.
      </p>
      <p>
        The bottom right corner shows the canvas in real size (128x64 pixels).
        Saved images will have the same resolution. The checkerboard background
        is not part of the image and serves as a visual aid.
      </p>
      <p class="q-mb-none">
        Note that Kiisu has to be unlocked to be able to show the image on the
        screen.
      </p>
    </template>
  </GenericPageLayout>
</template>

<script setup lang="ts">
import { GenericPageLayout } from 'shared/components/GenericPageLayout'
import { computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { throttle } from 'quasar'

import { showNotif } from 'shared/lib/utils/useShowNotif'
import { rpcErrorHandler } from 'shared/lib/utils/useRpcUtils'

import { imageDataToXBM } from 'shared/lib/utils/pixeleditor/xbm'

import {
  PaintPixelEditor,
  PaintPixelControls
} from 'features/Paint/PixelEditor'
import { PaintDitherCard } from 'features/Paint/Dither'
import { PaintMirror, PaintModel } from 'entity/Paint'
const paintStore = PaintModel.usePaintStore()
const pe = computed(() => paintStore.pe)

import { FlipperModel } from 'entity/Flipper'
const flipperStore = FlipperModel.useFlipperStore()

const componentName = 'Paint'

const mouseUp = () => {
  if (!pe.value) {
    return
  }
  if (pe.value.drawing) {
    if (pe.value.mode === 'line') {
      pe.value.save()
      pe.value.plotLine(pe.value.p0, pe.value.p1)
      pe.value.draw()
      pe.value.updated()
    } else if (pe.value.mode === 'rect') {
      pe.value.save()
      pe.value.plotRect(pe.value.p0, pe.value.p1)
      pe.value.draw()
      pe.value.updated()
    }
    pe.value.drawing = false
  }
}

const drawImage = (imageData: ImageData) => {
  paintStore.flags.ditherDialog = false
  const pixelData = []
  for (let i = 0; i < imageData.data.length; i += 4) {
    if (
      imageData.data[i]! + imageData.data[i + 1]! + imageData.data[i + 2]! ===
      0
    ) {
      pixelData.push(1)
    } else {
      pixelData.push(0)
    }
  }
  pe.value?.setData(pixelData)
}

const startVirtualDisplay = async () => {
  await flipperStore.flipper
    ?.RPC('guiStartVirtualDisplay')
    .then(() => {
      console.log('guiStartVirtualDisplay enable')
    })
    .catch((error: Error) => {
      rpcErrorHandler({
        componentName,
        error,
        command: 'guiStartVirtualDisplay'
      })
      showNotif({
        message: "Couldn't start virtual display session",
        color: 'negative'
      })
      throw error
    })
}
const stopVirtualDisplay = async () => {
  // if (flipperStore.isElectron) {
  //   for (let index = 0; index < flipperStore.availableFlippers.length; index++) {
  //     const flipper = flipperStore.availableFlippers[index];

  //     if (flipper.name !== flipperStore.flipper?.name) {
  //       await flipper
  //         ?.RPC('guiStopVirtualDisplay')
  //         .then(() => {
  //           console.log('guiStartVirtualDisplay disabled')
  //         })
  //         .catch(/* (error: Error) => rpcErrorHandler({ componentName, error, command: 'guiStopVirtualDisplay' }) */)
  //     }
  //   }
  // } else {
  await flipperStore.flipper
    ?.RPC('guiStopVirtualDisplay')
    .then(() => {
      console.log('guiStartVirtualDisplay disabled')
    })
    .catch((error: Error) =>
      rpcErrorHandler({
        componentName,
        error,
        command: 'guiStopVirtualDisplay'
      })
    )
  // }
}
const enableBacklight = throttle(async () => {
  await flipperStore.flipper
    ?.RPC('guiSendInputEvent', { key: 'OK', type: 'PRESS' })
    .catch((error: Error) =>
      rpcErrorHandler({ componentName, error, command: 'guiSendInputEvent' })
    )
  await flipperStore.flipper
    ?.RPC('guiSendInputEvent', { key: 'OK', type: 'SHORT' })
    .catch((error: Error) =>
      rpcErrorHandler({ componentName, error, command: 'guiSendInputEvent' })
    )
  await flipperStore.flipper
    ?.RPC('guiSendInputEvent', { key: 'OK', type: 'RELEASE' })
    .catch((error: Error) =>
      rpcErrorHandler({ componentName, error, command: 'guiSendInputEvent' })
    )
}, 1000)
const sendFrame = throttle(async () => {
  if (pe.value) {
    const imageData = pe.value.toImageData()
    const xbmBytes = imageDataToXBM(imageData)
    await flipperStore.flipper?.RPC('guiScreenFrame', {
      data: new Uint8Array(xbmBytes)
    })
  }
}, 100)

const handleInteraction = (event: MouseEvent | KeyboardEvent) => {
  if (
    (event instanceof MouseEvent && event.buttons) ||
    (event instanceof KeyboardEvent &&
      (event.code === 'ArrowRight' ||
        event.code === 'ArrowLeft' ||
        event.code === 'ArrowDown' ||
        event.code === 'ArrowUp') &&
      pe.value?.drawing)
  ) {
    enableBacklight()
    sendFrame()
  }
}

paintStore.setCallbackFrame(() => {
  enableBacklight()
  sendFrame()
})

onMounted(async () => {
  if (flipperStore.flipperReady) {
    if (!flipperStore.rpcActive) {
      await flipperStore.flipper?.startRPCSession()
    }

    await startVirtualDisplay()
  }
})

watch(
  () => flipperStore.flipper?.flipperReady,
  async (newValue) => {
    if (newValue) {
      await startVirtualDisplay()
    } else {
      if (!flipperStore.isElectron) {
        await stopVirtualDisplay()
      }
    }
  }
)

watch(
  () => flipperStore.flags.switchFlipper,
  async (newValue, oldValue) => {
    if (newValue !== oldValue && newValue === true && oldValue === false) {
      await stopVirtualDisplay()
    }
  }
)

onBeforeUnmount(() => {
  stopVirtualDisplay()
})
</script>

<style src="shared/lib/utils/pixeleditor/pixeleditor.css"></style>
<style lang="scss" scoped>
:deep(.paint .pE) {
  border: none;
}
:deep(.paint .pE .pE__drawing) {
  cursor: none;
}
</style>
