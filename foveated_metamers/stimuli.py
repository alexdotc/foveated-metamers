"""code to assemble stimuli for running experiment
"""
import imageio
import warnings
import numpy as np
from skimage import util


def pad_image(image, pad_mode, save_path=None, constant_values=.5, **pad_kwargs):
    r"""Pad an image using ``skimage.util.pad``

    Currently, we only support grayscale images

    All additional kwargs are passed directly to ``skimage.util.pad``

    Parameters
    ----------
    image : str or np.array
        Either an image array or a string containing the path to an
        image. If it's a string, we load it in as a grayscale image. If
        an image, we check that it only has 2 dimensions (i.e., is
        grayscale) and raise an Exception if not
    pad_mode : str
        A valid ``pad_mode`` for ``skimage.util.pad`` (see that function
        for more description). For our purposes, probably ``'constant'``
        or ``'symmetric'``
    save_path : str or None, optional
        If a str, the path to save the padded image at. If None, we
        don't save
    constant_values : sequence or int, optional
        The values to set the the padded values to for each axis. See
        ``skimage.util.pad`` for more details. If ``pad_mode`` is not
        ``'constant'``, we ignore this.

    Returns
    -------
    padded_image : np.array
        The padded image

    """
    if isinstance(image, str):
        image = imageio.imread(image, as_gray=True)
    else:
        if image.ndim > 2:
            raise Exception("We need image to be grayscale!")
    if image.max() > 1:
        warnings.warn("Assuming image range is (0, 255)")
        image /= 255
    if pad_mode == 'constant':
        pad_kwargs['constant_values'] = constant_values
    image = util.pad(image, int(image.shape[0]/2), pad_mode, **pad_kwargs)
    if save_path is not None:
        imageio.imwrite(save_path, image)
    return image


def collect_images(image_paths, save_path=None):
    r"""Collect images into a single array

    We loop through a list of paths, loading in images (as grayscale),
    stack them so that the different images are indexed along the first
    dimension, and then cast them as ``np.uint8``. We finally optionally
    save them and return.

    Parameters
    ----------
    image_paths : list
        A list of strs, each of which is the path to an image
    save_path : str or None, optional
        The path to save the resulting np.array at. If None, we don't
        save

    Returns
    -------
    images : np.array
        The stacked array of grayscale images
    """
    images = []
    for i in image_paths:
        images.append(imageio.imread(i, as_gray=True))
    # want our images to be indexed along the first dimension
    images = np.einsum('ijk -> kij', np.dstack(images)).astype(np.uint8)
    if save_path is not None:
        np.save(save_path, images)
    return images
