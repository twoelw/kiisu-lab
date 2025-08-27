<template>
  <div class="column items-center">
    <h5 class="q-mb-md q-mt-none text-bold">{{ props.flipperName }}</h5>
    <div ref="flipperContainer" class="flipper relative-position" :class="flipperBodyClass">
      <div
        class="flipper__display-wrapper relative-position"
        :style="`width: 128px; height: 64px; top: ${OFFSET_Y}px; left: ${OFFSET_X}px; transform: rotate(${90 * rotationCalculation}deg) scale(${SCALE_FACTOR}); transform-origin: top left;`"
      >
        <div
          v-if="!showScreenUpdating"
          class="flipper__expand-wrapper cursor-pointer"
          :style="'inset: 0'"
          @click="expandView"
        >
          <div class="dimmed" />
          <q-icon
            class="absolute-center"
            name="mdi-arrow-expand"
            size="64px"
            color="primary"
          />
        </div>

  <!-- Updating overlay -->
  <q-inner-loading :showing="showScreenUpdating" class="flipper__overlay" :style="'inset: 0'">
          <q-spinner size="42px" color="primary" />
        </q-inner-loading>

        <canvas
          v-show="isScreenStream"
          :width="128 * internalScale"
          :height="64 * internalScale"
          style="image-rendering: pixelated; width: 100%; height: 100%"
          ref="screenStreamCanvas"
        />
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'

type Props = {
  flipperName?: string
  flipperColor?: string
  showScreenUpdating: boolean
  isScreenStream?: boolean
  screenScale?: number
  orientation?: number
}

const props = withDefaults(defineProps<Props>(), {
  flipperColor: '2',
  showScreenUpdating: false,
  isScreenStream: false,
  screenScale: 1,
  orientation: 0
})

const emit = defineEmits(['expandView'])

const flipperBodyClass = computed(() => {
  switch (props.flipperColor) {
    case '1':
      return 'body-black'
    case '3':
      return 'body-transparent'
    default:
      return 'body-white'
  }
})

const rotationCalculation = computed(() => {
  switch (props.orientation) {
    case 1:
      return 2

    default:
      return 0
  }
})
const expandView = () => {
  emit('expandView')
}

const screenStreamCanvas = ref<HTMLCanvasElement>()
const flipperContainer = ref<HTMLDivElement>()

// Tweakable preview positioning (px)
const OFFSET_X = 45
const OFFSET_Y = 33
// Tweakable size multiplier (< 1 = smaller, > 1 = larger)
const SCALE_FACTOR = 0.7
const internalScale = ref<number>(props.screenScale || 1)

const computeScale = () => {
  const el = flipperContainer.value
  if (!el) return
  // use clientBox with aspect-ratio applied
  const availableW = Math.max(0, el.clientWidth - OFFSET_X)
  const availableH = Math.max(0, el.clientHeight - OFFSET_Y)
  const scaleX = availableW / 128
  const scaleY = availableH / 64
  const bestFit = Math.min(scaleX, scaleY)
  // Use integer scale for crisp pixels; visual size is further adjusted by CSS SCALE_FACTOR
  const integerScale = Math.max(1, Math.floor(bestFit))
  internalScale.value = integerScale
}

const onResize = () => computeScale()

onMounted(() => {
  computeScale()
  window.addEventListener('resize', onResize)
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', onResize)
})
defineExpose({
  screenStreamCanvas
})
</script>

<style lang="scss" scoped>
@import 'styles';
</style>
