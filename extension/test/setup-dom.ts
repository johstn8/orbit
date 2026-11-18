// jsdom has no layout engine: give every element a non-zero box so visibility checks behave like a browser.
export function fakeLayout() {
  (Element.prototype as any).getBoundingClientRect = function () {
    return { x: 10, y: 10, top: 10, left: 10, bottom: 30, right: 110, width: 100, height: 20, toJSON() {} };
  };
  (Element.prototype as any).scrollIntoView = function () {};
  (document as any).elementFromPoint = () => null;
  (document as any).execCommand = () => false;
}
