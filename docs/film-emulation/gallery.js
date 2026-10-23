'use strict';
const photos = [...document.querySelectorAll('.chapter .photo')].map(button => ({
  source: button.querySelector('img').getAttribute('src').replace('-preview.jpg', '.jpg'),
  alt: button.querySelector('img').alt,
  name: button.closest('figure').querySelector('figcaption span').textContent
}));
const viewer = document.querySelector('#viewer');
const image = document.querySelector('#viewer-photo');
const imageArea = document.querySelector('.viewer-image');
const error = document.querySelector('#viewer-error');
let selected = 0;
let request = 0;
async function showPhoto(index) {
  selected = (index + photos.length) % photos.length;
  const photo = photos[selected], token = ++request;
  document.querySelector('#viewer-count').textContent = `${String(selected + 1).padStart(2, '0')} / ${photos.length} — ${photo.name}`;
  document.querySelector('#viewer-caption').textContent = photo.alt;
  document.querySelector('#original-link').href = photo.source;
  imageArea.setAttribute('aria-busy', 'true');
  error.hidden = true;
  const next = new Image();
  next.src = photo.source;
  try {
    await next.decode();
    if (token !== request) return;
    image.src = photo.source;
    image.alt = photo.alt;
  } catch {
    if (token === request) error.hidden = false;
  } finally {
    if (token === request) imageArea.setAttribute('aria-busy', 'false');
  }
}
document.querySelectorAll('.photo').forEach(button => button.addEventListener('click', () => {
  viewer.showModal();
  document.body.classList.add('viewing');
  showPhoto(Number(button.dataset.index));
}));
document.querySelector('#close').addEventListener('click', () => viewer.close());
viewer.addEventListener('close', () => { document.body.classList.remove('viewing'); request++; });
document.querySelector('#previous').addEventListener('click', () => showPhoto(selected - 1));
document.querySelector('#next').addEventListener('click', () => showPhoto(selected + 1));
viewer.addEventListener('keydown', event => {
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
    event.preventDefault();
    showPhoto(selected + (event.key === 'ArrowRight' ? 1 : -1));
  }
});
