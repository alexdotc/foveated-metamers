#!/usr/bin/python
"""create metamers for the experiment
"""
import torch
import argparse
import imageio
import warnings
import numpy as np
import plenoptic as po
import pyrtools as pt
import os.path as op
import matplotlib as mpl
# by default matplotlib uses the TK gui toolkit which can cause problems
# when I'm trying to render an image into a file, see
# https://stackoverflow.com/questions/27147300/matplotlib-tcl-asyncdelete-async-handler-deleted-by-the-wrong-thread
mpl.use('Agg')


def setup_image(image, device):
    r"""setup the image

    We load in the image, if it's not already done so (converting it to
    gray-scale in the process), make sure it lies between 0 and 1, and
    make sure it's a tensor of the correct type and specified device

    Parameters
    ----------
    image : str or array_like
        Either the path to the file to load in or the loaded-in
        image. If array_like, we assume it's already 2d (i.e.,
        grayscale)
    device : torch.device
        The torch device to put the image on

    Returns
    -------
    image : torch.Tensor
        The image tensor, ready to go

    """
    if isinstance(image, str):
        print("Loading in reference image from %s" % image)
        # use imageio.imread in order to handle rgb correctly. this uses the ITU-R 601-2 luma
        # transform, same as matlab
        image = imageio.imread(image, as_gray=True)
    if image.max() > 1:
        warnings.warn("Assuming image range is (0, 255)")
        image /= 255
    else:
        warnings.warn("Assuming image range is (0, 1)")
    image = torch.tensor(image, dtype=torch.float32, device=device)
    while image.ndimension() < 4:
        image = image.unsqueeze(0)
    return image


def setup_model(model_name, scaling, image, min_ecc, max_ecc, device, cache_dir):
    r"""setup the model

    We initialize the model, with the specified parameters, and return
    it with the appropriate figsize.

    Parameters
    ----------
    model_name : {'RGC', 'V1'}
        Which type of model to create.
    scaling : float
        The scaling parameter for the model
    image : torch.tensor or np.array
        The image we will call the model on. This is only necessary
        because we need to know how big it is; we just use its shape
    min_ecc : float
        The minimum eccentricity for the pooling windows (see
        plenoptic.simul.VentralStream for more details)
    max_ecc : float
        The maximum eccentricity for the pooling windows (see
        plenoptic.simul.VentralStream for more details)
    device : torch.device
        The torch device to put the model on
    cache_dir : str or None, optional
        The directory to cache the windows tensor in. If set, we'll look
        there for cached versions of the windows we create, load them if
        they exist and create and cache them if they don't. If None, we
        don't check for or cache the windows.

    Returns
    -------
    model : plenoptic.simul.VentralStream
        A ventral stream model, ready to use
    figsize : tuple
        The figsize tuple to use with ``metamer.animate`` or other
        plotting functions

    """
    if model_name == 'RGC':
        model = po.simul.RetinalGanglionCells(scaling, image.shape[-2:], min_eccentricity=min_ecc,
                                              max_eccentricity=max_ecc, transition_region_width=1,
                                              cache_dir=cache_dir)
        figsize = (17, 5)
        # default figsize arguments work for an image that is 256x256,
        # may need to expand. we go backwards through figsize because
        # figsize and image shape are backwards of each other:
        # image.shape's last two indices are (height, width), while
        # figsize is (width, height)
        figsize = tuple([s*max(1, image.shape[::-1][i]/256) for i, s in enumerate(figsize)])
        rescale_factor = np.mean([image.shape[i+2]/256 for i in range(2)])
    elif model_name.startswith('V1'):
        model = po.simul.PrimaryVisualCortex(scaling, image.shape[-2:], min_eccentricity=min_ecc,
                                             max_eccentricity=max_ecc, transition_region_width=1,
                                             device=device, normalize=model_name.endswith('norm'),
                                             cache_dir=cache_dir)
        figsize = (35, 11)
        # default figsize arguments work for an image that is 512x512,
        # may need to expand. we go backwards through figsize because
        # figsize and image shape are backwards of each other:
        # image.shape's last two indices are (height, width), while
        # figsize is (width, height)
        figsize = tuple([s*max(1, image.shape[::-1][i]/512) for i, s in enumerate(figsize)])
        rescale_factor = np.mean([image.shape[i+2]/512 for i in range(2)])
    else:
        raise Exception("Don't know how to handle model_name %s" % model_name)
    # 10 and 12 are the default font sizes for labels and titles,
    # respectively, and we want to scale them in order to keep them
    # readable. this should be global to matplotlib and so propagate
    # through
    mpl.rc('axes', labelsize=rescale_factor*10, titlesize=rescale_factor*12)
    mpl.rc('xtick', labelsize=rescale_factor*10)
    mpl.rc('ytick', labelsize=rescale_factor*10)
    mpl.rc('lines', linewidth=rescale_factor*1.5, markersize=rescale_factor*6)
    model.to(device)
    return model, figsize


def add_center_to_image(model, initial_image, reference_image):
    r"""Add the center back to the metamer image

    The VentralStream class of models will do nothing to the center of
    the image (they don't see the fovea), so we add the fovea to the
    initial image before synthesis.

    Parameters
    ----------
    model : plenoptic.simul.VentralStream
        The model used to create the metamer. Specifically, we need its
        windows attribute
    initial_image : torch.Tensor
        The initial image we will use for metamer synthesis. Probably a
        bunch of white noise
    reference_image : torch.Tensor
        The reference/target image for synthesis
        (``metamer.target_image``)

    Returns
    -------
    metamer_image : torch.Tensor
        The metamer image with the center added back in

    """
    windows = model.PoolingWindows.windows[0].flatten(0, -3)
    # for some reason ~ (invert) is not implemented for booleans in
    # pytorch yet, so we do this instead.
    return ((windows.sum(0) * initial_image) + ((1 - windows.sum(0)) * reference_image))


def save(save_path, metamer, figsize):
    r"""save the metamer output

    We save three things here:
    - The metamer object itself, at ``save_path``. This contains, among
      other things, the saved image and representation over the course
      of synthesis.
    - The finished metamer image, at ``os.path.splitext(save_path)[0] +
      "_metamer.png"``. This is not just ``metamer.matched_image``, but
      has had the center added back in, as done by
      ``finalize_metamer_image``
    - The video showing synthesis progress at
      ``os.path.splitext(save_path)[0] + "_synthesis.mp4"``. We use this
      to visualize the optimization progress.

    Parameters
    ----------
    save_path : str
        The path to save the metamer object at, which we use as a
        starting-point for the other save paths
    metamer : plenoptic.synth.Metamer
        The metamer object after synthesis
    figsize : tuple
        The tuple describing the size of the figure for the synthesis
        video, as returned by ``setup_model``.

    """
    print("Saving at %s" % save_path)
    metamer.save(save_path, save_model_reduced=True)
    # save png of metamer
    metamer_path = op.splitext(save_path)[0] + "_metamer.png"
    print("Saving metamer image at %s" % metamer_path)
    imageio.imwrite(metamer_path, po.to_numpy(metamer.matched_image).squeeze())
    video_path = op.splitext(save_path)[0] + "_synthesis.mp4"
    print("Saving synthesis video at %s" % video_path)
    anim = metamer.animate(figsize=figsize)
    anim.save(video_path)


def setup_initial_image(initial_image_type, model, image, device):
    r"""setup the initial image

    Parameters
    ----------
    initial_image_type : {'white', 'pink', 'gray', 'blue'}
        What to use for the initial image. If 'white', we use white
        noise. If 'pink', we use pink noise
        (``pyrtools.synthetic_images.pink_noise(fract_dim=1)``). If
        'blue', we use blue noise
        (``pyrtools.synthetic_images.blue_noise(fract_dim=1)``). If
        'gray', we use a flat image with values of .5 everywhere (note
        that this one should only be used for the RGC model; it will
        immediately break the V1 and V2 models, since it has no energy
        at many frequencies)
    model : plenoptic.simul.VentralStream
        The model used to create the metamer. Specifically, we need its
        windows attribute
    image : torch.Tensor
        The reference image tensor
    device : torch.device
        The torch device to put the image on

    Returns
    -------
    initial_image : torch.Tensor
        The initial image to pass to metamer.synthesize

    """
    if initial_image_type == 'white':
        initial_image = torch.rand_like(image, device=device, dtype=torch.float32)
    elif initial_image_type == 'gray':
        initial_image = .5 * torch.ones_like(image, device=device, dtype=torch.float32)
    elif initial_image_type == 'pink':
        # this `.astype` probably isn't necessary, but just in case
        initial_image = pt.synthetic_images.pink_noise(image.shape[-2:]).astype(np.float32)
        # need to rescale this so it lies between 0 and 1
        initial_image += np.abs(initial_image.min())
        initial_image /= initial_image.max()
        initial_image = torch.Tensor(initial_image).unsqueeze(0).unsqueeze(0).to(device)
    elif initial_image_type == 'blue':
        # this `.astype` probably isn't necessary, but just in case
        initial_image = pt.synthetic_images.blue_noise(image.shape[-2:]).astype(np.float32)
        # need to rescale this so it lies between 0 and 1
        initial_image += np.abs(initial_image.min())
        initial_image /= initial_image.max()
        initial_image = torch.Tensor(initial_image).unsqueeze(0).unsqueeze(0).to(device)
    else:
        raise Exception("Don't know how to handle initial_image_type %s! Must be one of {'white',"
                        " 'gray', 'pink', 'blue'}" % initial_image_type)
    initial_image = add_center_to_image(model, initial_image, image)
    return torch.nn.Parameter(initial_image)


def main(model_name, scaling, image, seed=0, min_ecc=.5, max_ecc=15, learning_rate=1, max_iter=100,
         loss_thresh=1e-4, save_path=None, initial_image_type='white', gpu_num=None,
         cache_dir=None):
    r"""create metamers!

    Given a model_name, model parameters, a target image, and some
    optimization parameters, we do our best to synthesize a metamer,
    saving the outputs after it finishes.

    Parameters
    ----------
    model_name : {'RGC', 'V1', 'V1-norm'}
        Which type of model to create.
    scaling : float
        The scaling parameter for the model
    image : str or array_like
        Either the path to the file to load in or the loaded-in
        image. If array_like, we assume it's already 2d (i.e.,
        grayscale)
    seed : int, optional
        The number to use for initializing numpy and torch's random
        number generators
    min_ecc : float, optional
        The minimum eccentricity for the pooling windows (see
        plenoptic.simul.VentralStream for more details)
    max_ecc : float, optional
        The maximum eccentricity for the pooling windows (see
        plenoptic.simul.VentralStream for more details)
    learning_rate : float, optional
        The learning rate to pass to metamer.synthesize's optimizer
    max_iter : int, optional
        The maximum number of iterations we allow the synthesis
        optimization to run for
    loss_thresh : float, optional
        The loss threshold. If our loss is every below this, we stop
        synthesis and consider ourselves done.
    save_path : str or None, optional
        If a str, the path to the file to save the metamer object to. If
        None, we don't save the synthesis output (that's probably a bad
        idea)
    initial_image_type : {'white', 'pink', 'gray', 'blue'}
        What to use for the initial image. If 'white', we use white
        noise. If 'pink', we use pink noise
        (``pyrtools.synthetic_images.pink_noise(fract_dim=1)``). If
        'blue', we use blue noise
        (``pyrtools.synthetic_images.blue_noise(fract_dim=1)``). If
        'gray', we use a flat image with values of .5 everywhere (note
        that this one should only be used for the RGC model; it will
        immediately break the V1 and V2 models, since it has no energy
        at many frequencies)
    gpu_num : int or None, optional
        If not None and if torch.cuda.is_available(), we try to use the
        gpu whose number corresponds to gpu_num (WARNING: this means we
        assume that you have already checked that this gpu is
        available). else, we use the cpu
    cache_dir : str or None, optional
        The directory to cache the windows tensor in. If set, we'll look
        there for cached versions of the windows we create, load them if
        they exist and create and cache them if they don't. If None, we
        don't check for or cache the windows.

    """
    print("Using seed %s" % seed)
    torch.manual_seed(seed)
    np.random.seed(seed)
    if torch.cuda.is_available() and gpu_num is not None:
        device = torch.device("cuda:%s" % gpu_num)
    else:
        device = torch.device("cpu")
    print("On device %s" % device)
    image = setup_image(image, device)
    model, figsize = setup_model(model_name, scaling, image, min_ecc, max_ecc, device, cache_dir)
    print("Using model %s from %.02f degrees to %.02f degrees" % (model_name, min_ecc, max_ecc))
    print("Using learning rate %s, loss_thresh %s, and max_iter %s" % (learning_rate, loss_thresh,
                                                                       max_iter))
    clamper = po.RangeClamper((0, 1))
    metamer = po.synth.Metamer(image, model)
    initial_image = setup_initial_image(initial_image_type, model, image, device)
    if save_path is not None:
        save_progress = True
    else:
        save_progress = False
    matched_im, matched_rep = metamer.synthesize(clamper=clamper, store_progress=10,
                                                 learning_rate=learning_rate, max_iter=max_iter,
                                                 loss_thresh=loss_thresh, seed=seed,
                                                 initial_image=initial_image,
                                                 save_progress=save_progress, save_path=save_path)
    if save_path is not None:
        save(save_path, metamer, figsize)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Create some metamers!",
                                     formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('model_name', help="Name of the model to create: {'RGC', 'V1', 'V1-norm'}")
    parser.add_argument('scaling', type=float, help="The scaling parameter for the model")
    parser.add_argument('image', help=("Path to the image to use as the reference for metamer "
                                       "synthesis"))
    parser.add_argument('--seed', '-s', type=int, default=0,
                        help=("The number to use for initializing numpy and torch's random "
                              "number generators"))
    parser.add_argument('--min_ecc', '-e0', type=float, default=.5,
                        help="The minimum eccentricity for the pooling windows")
    parser.add_argument('--max_ecc', '-em', type=float, default=15,
                        help="The maximum eccentricity for the pooling windows")
    parser.add_argument('--learning_rate', '-l', type=float, default=1,
                        help="The learning rate to pass to metamer.synthesize's optimizer")
    parser.add_argument('--max_iter', '-m', type=int, default=100,
                        help=("The maximum number of iterations we allow the synthesis "
                              "optimization to run for"))
    parser.add_argument('--loss_thresh', '-t', type=float, default=1e-4,
                        help=("The loss threshold. If our loss is every below this, we stop "
                              "synthesis and consider ourselves done."))
    parser.add_argument('--save_path', '-p', default='metamer.pt',
                        help=("The path to the file to save the metamer object to (should end in "
                              ".pt)"))
    parser.add_argument('--initial_image_type', '-i', default='white',
                        help=("{'white', 'pink', 'gray', 'blue'}. what to use for the initial "
                              "image. All are different colors of noise except gray, which is a "
                              "flat mid-gray image"))
    parser.add_argument('--gpu_num', '-g', default=None,
                        help=("If not None and if torch.cuda.is_available(), we try to use the gpu"
                              " whose number corresponds to gpu_num. else, we use the cpu"))
    parser.add_argument('--cache_dir', '-c', default=None,
                        help=("If not None, the directory to use for caching windows tensors. "
                              "Using this should greatly improve speed and memory usage on "
                              "subsequent runs, especially for small scaling values."))
    args = vars(parser.parse_args())
    try:
        gpu_num = int(args.pop('gpu_num'))
    except ValueError:
        gpu_num = None
    main(gpu_num=gpu_num, **args)
