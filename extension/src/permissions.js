// Opened in a tab when the mic or camera hasn't been allowed yet: extension
// popups can't show Chrome's permission prompt, a normal page can.
const params = new URLSearchParams(location.search);
const wantMic = params.get('mic') !== '0';
const wantCam = params.get('camera') === '1';
document.getElementById('what').textContent =
  wantMic && wantCam ? 'microphone and camera' : wantCam ? 'camera' : 'microphone';
const msg = document.getElementById('msg');

async function ask() {
  msg.textContent = '';
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: wantMic, video: wantCam });
    stream.getTracks().forEach((t) => t.stop());
    msg.className = 'msg ok';
    msg.textContent = 'Done. Open Screen Recorder again from the toolbar and press Start. This tab closes by itself.';
    await chrome.storage.local.set({ permissionsAsked: true });
    setTimeout(() => window.close(), 2500);
  } catch (error) {
    msg.className = 'msg err';
    msg.textContent = error?.name === 'NotFoundError'
      ? 'No microphone or camera was found. Plug one in and try again.'
      : 'Chrome blocked it. Click the camera/mic icon in the address bar, choose Allow, then press "Ask again".';
  }
}
document.getElementById('ask').addEventListener('click', ask);
ask();
