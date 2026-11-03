// The face-camera bubble shown on the page while recording.
(async () => {
  const video = document.querySelector('video');
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 640 }, height: { ideal: 640 }, facingMode: 'user' },
      audio: false,
    });
    video.srcObject = stream;
    addEventListener('pagehide', () => stream.getTracks().forEach((t) => t.stop()));
  } catch {
    video.hidden = true;
    document.querySelector('p').hidden = false;
  }
})();
