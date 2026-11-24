// WebKit may extend the selection across a wrapped line on a one-pixel move.
// Both reading and editing use the distance from the original press.
class TextSelectionGesture {
  constructor(event) {
    this.x = event.clientX;
    this.y = event.clientY;
    this.shifted = false;
    this.moved = false;
  }

  static plainPress(event) {
    return event.button === 0 && event.detail <= 1 && !event.defaultPrevented &&
      !event.shiftKey && !event.metaKey && !event.altKey && !event.ctrlKey;
  }

  isDrag(event) {
    const dx = event.clientX - this.x, dy = event.clientY - this.y;
    this.shifted ||= dx !== 0 || dy !== 0;
    this.moved ||= Math.hypot(dx, dy) >= 6;
    return this.moved;
  }
}
