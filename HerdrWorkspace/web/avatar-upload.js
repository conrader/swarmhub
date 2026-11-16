(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const fileInput = $("avatar-file");
  const canvas = $("avatar-canvas");
  const context = canvas.getContext("2d");
  let picture = null;
  let saved = null;
  let loading = false;
  let selection = 0;

  function status(message) {
    $("avatar-notice").textContent = message;
    $("avatar-notice").hidden = !message;
  }

  function showPicker() {
    $("avatar-picker").hidden = $("profile-avatar").value !== "image";
    $("avatar-existing").hidden = !saved?.avatar_key || Boolean(picture);
    $("avatar-crop").hidden = !picture;
  }

  function reset(profile = null) {
    ++selection;
    picture?.close();
    picture = null;
    loading = false;
    saved = profile;
    fileInput.value = "";
    status("");
    context?.clearRect(0, 0, canvas.width, canvas.height);
    $("avatar-zoom").value = "100";
    $("avatar-x").value = $("avatar-y").value = "50";
    if (profile?.avatar_key) {
      window.agentProfiles.avatar($("avatar-existing"), profile.name, profile.avatar, profile.id, profile.avatar_key);
    } else {
      window.agentProfiles.avatar($("avatar-existing"), "", "initial");
    }
    showPicker();
  }

  function paint() {
    if (!picture) return;
    const zoom = Number($("avatar-zoom").value) / 100;
    const side = Math.min(picture.width, picture.height) / zoom;
    const x = (picture.width - side) * Number($("avatar-x").value) / 100;
    const y = (picture.height - side) * Number($("avatar-y").value) / 100;
    $("avatar-x").disabled = picture.width - side < 1;
    $("avatar-y").disabled = picture.height - side < 1;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.imageSmoothingQuality = "high";
    context.drawImage(picture, x, y, side, side, 0, 0, canvas.width, canvas.height);
  }

  async function readable(file) {
    const head = new Uint8Array(await file.slice(0, 16).arrayBuffer());
    const at = (offset, sig) => sig.every((byte, index) => head[offset + index] === byte);
    return at(0, [137, 80, 78, 71, 13, 10, 26, 10])
      || at(0, [255, 216, 255])
      || (at(0, [82, 73, 70, 70]) && at(8, [87, 69, 66, 80]));
  }

  async function choose(file) {
    const request = ++selection;
    loading = true;
    picture?.close();
    picture = null;
    showPicker();
    status("Reading image…");
    let decoded;
    try {
      if (file.size > 5 * 1024 * 1024) throw new Error("Choose an image up to 5 MiB.");
      if (!await readable(file)) throw new Error("Choose a PNG, JPEG, or WebP image.");
      if (!context) throw new Error("The browser can’t crop this image.");
      decoded = await createImageBitmap(file);
      if (request !== selection) return;
      if (decoded.width * decoded.height > 24_000_000 || decoded.width > 8192 || decoded.height > 8192) {
        throw new Error("Choose an image with at most 24 million pixels and no side longer than 8192 pixels.");
      }
      picture = decoded;
      decoded = null;
      $("avatar-zoom").value = "100";
      $("avatar-x").value = $("avatar-y").value = "50";
      paint();
      status("");
    } catch (error) {
      if (request === selection) status(error instanceof DOMException ? "This image couldn’t be read." : error.message);
    } finally {
      decoded?.close();
      if (request === selection) {
        loading = false;
        showPicker();
      }
    }
  }

  function encode() {
    return new Promise((resolve, reject) => canvas.toBlob((blob) => {
      if (!blob) return reject(new Error("The avatar crop couldn’t be saved."));
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result.split(",", 2)[1]);
      reader.onerror = () => reject(new Error("The avatar crop couldn’t be saved."));
      reader.readAsDataURL(blob);
    }, "image/png"));
  }

  async function capture() {
    if ($("profile-avatar").value !== "image") return undefined;
    if (loading) throw new Error("Wait for the crop preview before saving.");
    if (picture) return encode();
    if (!saved?.avatar_key) throw new Error("Choose an image before saving.");
    return undefined;
  }

  $("profile-avatar").addEventListener("change", showPicker);
  fileInput.addEventListener("change", () => {
    const file = fileInput.files[0];
    if (file) void choose(file);
  });
  for (const key of ["avatar-zoom", "avatar-x", "avatar-y"]) {
    $(key).addEventListener("input", paint);
  }
  $("profile-dialog").addEventListener("close", () => {
    if (!$("profile-dialog").open) reset();
  });
  window.avatarUpload = { reset, capture };
})();
