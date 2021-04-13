"""code to generate figures for the project
"""
import imageio
import torch
import re
import yaml
import pandas as pd
import numpy as np
import pyrtools as pt
import plenoptic as po
from skimage import measure
import seaborn as sns
import matplotlib.pyplot as plt
import matplotlib as mpl
import os.path as op
import arviz as az
from . import utils, plotting, analysis, mcmc
import sys
sys.path.append(op.join(op.dirname(op.realpath(__file__)), '..', 'extra_packages'))
import plenoptic_part as pop


def add_cutout_box(axes, window_size=400, periphery_offset=(-800, -1000), colors='r',
                   linestyles='--', plot_fovea=True, plot_periphery=True, **kwargs):
    """add square to axes to show where the cutout comes from

    Parameters
    ----------
    axes : array_like
        arrays to add square to (different images should be indexed
        along first dimension)
    window_size : int
        The size of the cut-out to plot, in pixels (this is the length
        of one side of the square).
    periphery_offset : tuple
        Tuple of ints. How far from the fovea we want our peripheral
        cut-out to be. The order of this is the same as that returned by
        image.shape. Can be positive or negative depending on which
        direction you want to go
    colors, linestyle : str, optional
        color and linestyle to use for cutout box, see `plt.vlines()`
        and `plt.hlines()` for details
    plot_fovea : bool, optional
        whether to plot the foveal box
    plot_periphery : bool, optional
        whether to plot peripheral box
    kwargs :
        passed to `plt.vlines()` and `plt.hlines()`

    """
    axes = np.array(axes).flatten()
    for ax in axes:
        if len(ax.images) != 1:
            raise Exception("axis should only have one image on it!")
        im = ax.images[0]
        im_ctr = [s//2 for s in im.get_size()]
        fovea_bounds = np.array([im_ctr[0]-window_size//2, im_ctr[0]+window_size//2,
                                 im_ctr[1]-window_size//2, im_ctr[1]+window_size//2])
        if plot_fovea:
            ax.vlines(fovea_bounds[2:], fovea_bounds[0], fovea_bounds[1], colors=colors,
                      linestyles=linestyles, **kwargs)
            ax.hlines(fovea_bounds[:2], fovea_bounds[2], fovea_bounds[3], colors=colors,
                      linestyles=linestyles, **kwargs)
        if plot_periphery:
            ax.vlines(fovea_bounds[2:]-periphery_offset[1], fovea_bounds[0]-periphery_offset[0],
                      fovea_bounds[1]-periphery_offset[0], colors=colors,
                      linestyles=linestyles, **kwargs)
            ax.hlines(fovea_bounds[:2]-periphery_offset[0], fovea_bounds[2]-periphery_offset[1],
                      fovea_bounds[3]-periphery_offset[1], colors=colors,
                      linestyles=linestyles, **kwargs)


def add_fixation_cross(axes, cross_size=50, colors='r', linestyles='-', **kwargs):
    """add fixation cross to center of axes

    Parameters
    ----------
    axes : array_like
        arrays to add square to (different images should be indexed
        along first dimension)
    cross_size : int, optional
        total size of the lines in the cross, in pixels
    colors, linestyle : str, optional
        color and linestyle to use for cutout box, see `plt.vlines()`
        and `plt.hlines()` for details
    kwargs :
        passed to `plt.vlines()` and `plt.hlines()`

    """
    axes = np.array(axes).flatten()
    for ax in axes:
        if len(ax.images) != 1:
            raise Exception("axis should only have one image on it!")
        im = ax.images[0]
        im_ctr = [s//2 for s in im.get_size()]
        ax.vlines(im_ctr[1], im_ctr[0]-cross_size/2, im_ctr[0]+cross_size/2, colors=colors,
                  linestyles=linestyles, **kwargs)
        ax.hlines(im_ctr[0], im_ctr[1]-cross_size/2, im_ctr[1]+cross_size/2, colors=colors,
                  linestyles=linestyles, **kwargs)


def get_image_cutout(images, window_size=400, periphery_offset=(-800, -1000)):
    """get foveal and peripheral cutouts from images

    Parameters
    ----------
    images : array_like
        images to plot (different images should be indexed along first
        dimension)
    window_size : int
        The size of the cut-out to plot, in pixels (this is the length
        of one side of the square).
    periphery_offset : tuple
        Tuple of ints. How far from the fovea we want our peripheral
        cut-out to be. The order of this is the same as that returned by
        image.shape. Can be positive or negative depending on which
        direction you want to go

    Returns
    -------
    fovea, periphery : list
        lists of foveal and peripheral cutouts from images

    """
    if images.ndim == 2:
        images = images[None, :]
    im_ctr = [s//2 for s in images.shape[-2:]]
    fovea_bounds = [im_ctr[0]-window_size//2, im_ctr[0]+window_size//2,
                    im_ctr[1]-window_size//2, im_ctr[1]+window_size//2]
    fovea = [im[fovea_bounds[0]:fovea_bounds[1], fovea_bounds[2]:fovea_bounds[3]] for im in images]
    periphery = [im[fovea_bounds[0]-periphery_offset[0]:fovea_bounds[1]-periphery_offset[0],
                    fovea_bounds[2]-periphery_offset[1]:fovea_bounds[3]-periphery_offset[1]]
                 for im in images]
    return fovea, periphery


def cutout_figure(images, window_size=400, periphery_offset=(-800, -1000), max_ecc=30.2,
                  plot_fovea=True, plot_periphery=True):
    """create figure showing cutout views of different images

    if both `plot_fovea` and `plot_periphery` are False, this just
    returns None

    Parameters
    ----------
    images : array_like
        images to plot (different images should be indexed along first
        dimension)
    window_size : int
        The size of the cut-out to plot, in pixels (this is the length
        of one side of the square).
    periphery_offset : tuple
        Tuple of ints. How far from the fovea we want our peripheral
        cut-out to be. The order of this is the same as that returned by
        image.shape. Can be positive or negative depending on which
        direction you want to go
    max_ecc : float, optional
        The maximum eccentricity of the metamers, as passed to the
        model. Used to convert from pixels to degrees so we know the
        extent and location of the cut-out views in degrees.
    plot_fovea : bool, optional
        whether to plot the foveal cutout
    plot_periphery : bool, optional
        whether to plot peripheral cutout

    Returns
    -------
    fig :
        The matplotlib figure with the cutouts plotted on it

    """
    if not plot_fovea and not plot_periphery:
        return None
    fovea, periphery = get_image_cutout(images, window_size, periphery_offset)
    # max_ecc is the distance from the center to the edge of the image,
    # so we want double this to get the full width of the image
    pix_to_deg = (2 * max_ecc) / max(images.shape[-2:])
    window_extent_deg = (window_size//2) * pix_to_deg
    periphery_ctr_deg = np.sqrt(np.sum([(s*pix_to_deg)**2 for s in periphery_offset]))
    imgs_to_plot = []
    if plot_fovea:
        imgs_to_plot += fovea
    if plot_periphery:
        imgs_to_plot += periphery
        if plot_fovea:
            periphery_ax_idx = len(fovea)
        else:
            periphery_ax_idx = 0
    fig = pt.imshow(imgs_to_plot, vrange=(0, 1), title=None, col_wrap=len(fovea))
    if plot_fovea:
        fig.axes[0].set(ylabel='Fovea\n($\pm$%.01f deg)' % window_extent_deg)
    if plot_periphery:
        ylabel = 'Periphery\n(%.01f$\pm$%.01f deg)' % (periphery_ctr_deg, window_extent_deg)
        fig.axes[periphery_ax_idx].set(ylabel=ylabel)
    return fig


def scaling_comparison_figure(model_name, image_name, scaling_vals, seed, window_size=400,
                              periphery_offset=(-800, -1000), max_ecc=30.2, **kwargs):
    r"""Create a figure showing cut-out views of all scaling values

    We want to be able to easily visually compare metamers across
    scaling values (and with the reference image), but they're very
    large. In order to facilitate this, we create this figure with
    'cut-out' views, where we compare the reference image and metamers
    made with a variety of scaling values (all same seed) at the fovea
    and the periphery, with some information about the extent.

    Parameters
    ----------
    model_name : str
        Name(s) of the model(s) to run. Must begin with either V1 or
        RGC. If model name is just 'RGC' or just 'V1', we will use the
        default model name for that brain area from config.yml
    image_name : str
        The name of the reference image we want to examine
    scaling_vals : list
        List of floats which give the scaling values to compare. We'll
        plot the metamers in this order, so they should probably be in
        increasing order
    seed : int
        The metamer seed we're examining
    window_size : int
        The size of the cut-out to plot, in pixels (this is the length
        of one side of the square).
    periphery_offset : tuple
        Tuple of ints. How far from the fovea we want our peripheral
        cut-out to be. The order of this is the same as that returned by
        image.shape. Can be positive or negative depending on which
        direction you want to go
    max_ecc : float, optional
        The maximum eccentricity of the metamers, as passed to the
        model. Used to convert from pixels to degrees so we know the
        extent and location of the cut-out views in degrees.
    kwargs : dict
        Additional key, value pairs to pass to
        utils.generate_metamers_path for finding the images to include.

    Returns
    -------
    fig :
        The matplotlib figure with the scaling comparison plotted on it

    """
    gamma_corrected_image_name = utils.get_gamma_corrected_ref_image(image_name)
    ref_path = utils.get_ref_image_full_path(gamma_corrected_image_name)
    images = [utils.convert_im_to_float(imageio.imread(ref_path))]
    image_paths = utils.generate_metamer_paths(model_name, image_name=image_name,
                                               scaling=scaling_vals, seed=seed,
                                               max_ecc=max_ecc, **kwargs)
    for p in image_paths:
        corrected_p = p.replace('.png', '_gamma-corrected.png')
        images.append(utils.convert_im_to_float(imageio.imread(corrected_p)))
    # want our images to be indexed along the first dimension
    images = np.einsum('ijk -> kij', np.dstack(images))
    fig = cutout_figure(images, window_size, periphery_offset, max_ecc)
    fig.axes[0].set(title='Reference')
    for i, sc in zip(range(1, len(images)), scaling_vals):
        fig.axes[i].set(title='scaling=%.03f' % sc)
    return fig


def pooling_window_example(windows, image, target_eccentricity=24,
                           windows_scale=0, **kwargs):
    """Plot example window on image.

    This plots a single window, as close to the target_eccentricity as
    possible, at half-max amplitude, to visualize the size of the pooling
    windows

    Parameters
    ----------
    windows : pooling.PoolingWindows
        The PoolingWindows object to plot.
    image : np.ndarray or str
        The image to plot the window on. If a np.ndarray, then this should
        already lie between 0 and 1. If a str, must be the path to the image
        file,and we'll load it in.
    target_eccentricity : float, optional
        The approximate central eccentricity of the window to plot
    windows_scale : int, optional
        The scale of the windows to plot. If greater than 0, we down-sampled
        image by a factor of 2 that many times so they plot correctly.
    kwargs :
        Passed to pyrtools.imshow.

    Returns
    -------
    fig : plt.Figure
        The figure containing the plot.

    """
    if isinstance(image, str):
        image = utils.convert_im_to_float(imageio.imread(image))
    target_ecc_idx = abs(windows.central_eccentricity_degrees -
                         target_eccentricity).argmin()
    ecc_windows = (windows.ecc_windows[windows_scale] /
                   windows.norm_factor[windows_scale])
    target_amp = windows.window_max_amplitude / 2
    window = torch.einsum('hw,hw->hw',
                          windows.angle_windows[windows_scale][0],
                          ecc_windows[target_ecc_idx])

    # need to down-sample image for these scales
    for i in range(windows_scale):
        image = measure.block_reduce(image, (2, 2))
    fig = pt.imshow(image, title=None, **kwargs)
    fig.axes[0].contour(po.to_numpy(window).squeeze(), [target_amp],
                        colors='r', linewidths=5)
    return fig


def synthesis_schematic(metamer, iteration=0, plot_synthesized_image=True,
                        plot_rep_comparison=True, plot_signal_comparison=True,
                        **kwargs):
    """Create schematic of synthesis, for animating.

    WARNING: Currently, only works with images of size (256, 256), will need a
    small amount of tweaking to work with differently sized images. (And may
    never look quite as good with them)

    Parameters
    ----------
    metamer : pop.Metamer
        The Metamer object to grab data from
    iteration : int or None, optional
        Which iteration to display. If None, we show the most recent one.
        Negative values are also allowed.
    plot_synthesized_image : bool, optional
        Whether to plot the synthesized image or not.
    plot_rep_comparison : bool, optional
        Whether to plot a scatter plot comparing the synthesized and base
        representation.
    plot_signal_comparison : bool, optional
        Whether to plot the comparison of the synthesized and base
        images.
    kwargs :
        passed to metamer.plot_synthesis_status

    Returns
    -------
    fig : plt.Figure
        Figure containing the plot
    axes_idx : dict
        dictionary specifying which plot is where, for use with animate()

    Notes
    -----
    To successfully animate, call with same values for the args that start with
    `plot_`, pass fig and axes_idx, and set init_figure, plot_loss,
    plot_representation_error to False.

    """
    # arrangement was all made with 72 dpi
    mpl.rc('figure', dpi=72)
    mpl.rc('axes', titlesize=25)
    image_shape = metamer.base_signal.shape
    figsize = ((1.5+(image_shape[-1] / image_shape[-2])) * 4.5 + 2.5, 3*4.5+1)
    fig = plt.figure(figsize=figsize)
    gs = mpl.gridspec.GridSpec(3, 10, figure=fig, hspace=.25, bottom=.05,
                               top=.95, left=.05, right=.95)
    fig.add_subplot(gs[0, 0:3], aspect=1)
    fig.add_subplot(gs[0, 4:7], aspect=1)
    fig.add_subplot(gs[1, 1:4], aspect=1)
    fig.add_subplot(gs[1, 6:9], aspect=1)
    fig.add_subplot(gs[2, 0:3], aspect=1)
    fig.add_subplot(gs[2, 4:7], aspect=1)
    axes_idx = {'image': 0, 'signal_comp': 2, 'rep_comp': 3,
                'misc': [1] + list(range(4, len(fig.axes)))}
    po.imshow(metamer.base_signal, ax=fig.axes[4], title=None)
    if not plot_rep_comparison:
        axes_idx['misc'].append(axes_idx.pop('rep_comp'))
    if not plot_signal_comparison:
        axes_idx['misc'].append(axes_idx.pop('signal_comp'))
    for i in [0] + axes_idx['misc']:
        fig.axes[i].xaxis.set_visible(False)
        fig.axes[i].yaxis.set_visible(False)
        fig.axes[i].set_frame_on(False)
    model_axes = [5]
    if plot_synthesized_image:
        model_axes += [1]
    arrowkwargs = {'xycoords': 'axes fraction', 'textcoords': 'axes fraction',
                   'ha': 'center', 'va': 'center'}
    arrowprops = {'color': '0', 'connectionstyle': 'arc3', 'arrowstyle': '->',
                  'lw': 3}
    for i in model_axes:
        p = mpl.patches.Rectangle((0, .25), .5, .5, fill=False)
        p.set_transform(fig.axes[i].transAxes)
        fig.axes[i].add_patch(p)
        fig.axes[i].text(.25, .5, 'M', {'size': 50}, ha='center', va='center',
                         transform=fig.axes[i].transAxes)
        fig.axes[i].annotate('', (0, .5), (-.4, .5), arrowprops=arrowprops,
                             **arrowkwargs)
    if plot_rep_comparison:
        arrowprops['connectionstyle'] += ',rad=.3'
        fig.axes[5].annotate('', (1.2, 1.25), (.53, .5), arrowprops=arrowprops,
                             **arrowkwargs)
        if plot_synthesized_image:
            arrowprops['connectionstyle'] = 'arc3,rad=.2'
            fig.axes[1].annotate('', (.6, -.8), (.25, .22), arrowprops=arrowprops,
                                 **arrowkwargs)
    else:
        fig.axes[5].annotate('', (1.05, .5), (.53, .5), arrowprops=arrowprops,
                             **arrowkwargs)
        vector = "[{:.3f}, {:.3f}, ..., {:.3f}]".format(*np.random.rand(3))
        fig.axes[5].text(1.05, .5, vector, {'size': '25'}, transform=fig.axes[5].transAxes,
                         va='center', ha='left')
        if plot_synthesized_image:
            fig.axes[1].annotate('', (1.05, .5), (.53, .5), arrowprops=arrowprops,
                                 **arrowkwargs)
            vector = "[{:.3f}, {:.3f}, ..., {:.3f}]".format(*np.random.rand(3))
            fig.axes[1].text(1.05, .5, vector, {'size': '25'}, transform=fig.axes[1].transAxes,
                             va='center', ha='left')
    if plot_signal_comparison:
        arrowprops['connectionstyle'] = 'arc3'
        fig.axes[4].annotate('', (.8, 1.25), (.8, 1.03), arrowprops=arrowprops,
                             **arrowkwargs)
        if plot_synthesized_image:
            arrowprops['connectionstyle'] += ',rad=.1'
            fig.axes[0].annotate('', (.25, -.8), (.15, -.03), arrowprops=arrowprops,
                                 **arrowkwargs)
    fig = metamer.plot_synthesis_status(axes_idx=axes_idx, iteration=iteration,
                                        plot_rep_comparison=plot_rep_comparison,
                                        plot_synthesized_image=plot_synthesized_image,
                                        plot_loss=False,
                                        plot_signal_comparison=plot_signal_comparison,
                                        plot_representation_error=False, fig=fig,
                                        **kwargs)
    # plot_synthesis_status can update axes_idx
    axes_idx = metamer._axes_idx
    # I think plot_synthesis_status will turn this into a list (in the general
    # case, this can contain multiple plots), but for these models and Metamer,
    # it will always be a single value
    if 'rep_comp' in axes_idx.keys() and isinstance(axes_idx['rep_comp'], list):
        assert len(axes_idx['rep_comp']) == 1
        axes_idx['rep_comp'] = axes_idx['rep_comp'][0]
    fig.axes[0].set_title('')
    if plot_signal_comparison:
        fig.axes[2].set(xlabel='', ylabel='', title='Pixel values')
    if plot_rep_comparison:
        fig.axes[3].set(xlabel='', ylabel='')
    return fig, axes_idx


def synthesis_video(metamer_save_path, model_name=None):
    """Create video showing synthesis progress, for presentations.

    Creates videos showing the metamer, representation, and pixels over time.
    Works best if synthesis was run with store_progress=1, or some other low
    value. Will create three videos, so can be used for a build. Will be saved
    in the same directory as metamer_save_path, replacing the extension with
    _synthesis-0.mp4, _synthesis-1.mp4, and synthesis-2.mp4

    WARNING: This will be very memory-intensive and may take a long time to
    run, depending on how many iterations synthesis ran for.

    Parameters
    ----------
    metamer_save_path : str
        Path to the .pt file containing the complete saved metamer
    model_name : str or None, optional
        str giving the model name. If None, we try and infer it from
        metamer_save_path

    """
    mpl.rc('axes.spines', right=False, top=False)
    if model_name is None:
        # try to infer from path
        model_name = re.findall('/((?:RGC|V1)_.*?)/', metamer_save_path)[0]
    if model_name.startswith('RGC'):
        model_constructor = pop.PooledRGC.from_state_dict_reduced
    elif model_name.startswith('V1'):
        model_constructor = pop.PooledV1.from_state_dict_reduced
    metamer = pop.Metamer.load(metamer_save_path, model_constructor=model_constructor)
    kwargs = {'plot_synthesized_image': False, 'plot_rep_comparison': False,
              'plot_signal_comparison': False}
    formats = ['png', 'png', 'png', 'mp4', 'png', 'mp4']
    for i, f in enumerate(formats):
        path = op.splitext(metamer_save_path)[0] + f"_synthesis-{i}.{f}"
        print(f"Saving synthesis-{i} {f} at {path}")
        if i == 1:
            kwargs['plot_synthesized_image'] = True
        elif i == 2:
            kwargs['plot_rep_comparison'] = True
        elif i == 4:
            kwargs['plot_signal_comparison'] = True
            kwargs['iteration'] = None
        else:
            # otherwise, don't specify iteration
            kwargs.pop('iteration', None)
        np.random.seed(0)
        fig, axes_idx = synthesis_schematic(metamer, **kwargs)
        # remove ticks because they don't matter here
        if i >= 2:
            fig.axes[axes_idx['rep_comp']].set(xticks=[], yticks=[])
        if i >= 4:
            fig.axes[axes_idx['signal_comp']].set(xticks=[], yticks=[])
        if f == 'mp4':
            anim = metamer.animate(fig=fig, axes_idx=axes_idx,
                                   plot_loss=False, init_figure=False,
                                   plot_representation_error=False, **kwargs)
            anim.save(path)
        else:
            fig.savefig(path)


def pooling_window_area(windows, windows_scale=0, units='degrees'):
    """Plot window area as function of eccentricity.

    Plots the area of the window bands as function of eccentricity, with a
    horizontal line corresponding to a single pixel.

    Parameters
    ----------
    windows : pooling.PoolingWindows
        The PoolingWindows object to plot.
    windows_scale : int, optional
        The scale of the windows to plot. If units=='degrees', only the
        one-pixel line will change for different scales (in pixels, areas will
        drop by factor of 4).
    units: {'degrees', 'pixels'}, optional
        Which unit to plot eccentricity and area in.

    Returns
    -------
    fig : plt.Figure
        The figure containing the plot.

    """
    fig = windows.plot_window_areas(units, scale_num=windows_scale,
                                    figsize=(15, 5))
    if units == 'degrees':
        # half is the smallest windows (for our models, which use gaussian
        # windows), full the largest.
        ylim = (windows.window_approx_area_degrees['half'].min(),
                windows.window_approx_area_degrees['full'].max())
        one_pixel_line = 1 / windows.deg_to_pix[windows_scale]
    elif units == 'pixels':
        # half is the smallest windows (for our models, which use gaussian
        # windows), full the largest.
        ylim = (windows.window_approx_area_pixels['half'].min(),
                windows.window_approx_area_pixels['full'].max())
        one_pixel_line = 1
    ylim = plotting.get_log_ax_lims(np.array(ylim), base=10)
    xlim = fig.axes[0].get_xlim()
    fig.axes[0].hlines(one_pixel_line, *xlim, colors='r', linestyles='--',
                       label='one pixel')
    fig.axes[0].set(yscale='log', xscale='log', ylim=ylim, xlim=xlim,
                    title=("Window area as function of eccentricity.\n"
                           "Half: at half-max amplitude, Full: $\pm$ 3 std dev, Top: 0 for Gaussians\n"
                           "Area is radial width * angular width * $\pi$/4\n"
                           "(radial width is double angular at half-max, "
                           "more than that at full, but ratio approaches "
                           "two as scaling shrinks / windows get smaller)"))
    fig.axes[0].legend()
    return fig


def synthesis_pixel_diff(stim, stim_df, scaling):
    """Show average pixel-wise squared error for a given scaling value.

    WARNING: This is reasonably memory-intensive.

    stim has dtype np.uint8. We convert back to np.float32 (and rescale to [0,
    1] interval) for these calculations.

    Parameters
    ----------
    stim : np.ndarray
        The array of metamers we want to check, should correspond to stim_df
    stim_df : pd.DataFrame
        The metamer information dataframe, as created by
        stimuli.create_metamer_df
    scaling : float
        The scaling value to check

    Returns
    -------
    fig : plt.Figure
        The figure containing the plot.
    errors : np.ndarray
        array of shape (stim_df.image_name.nunique(), *stim.shape[-2:])
        containing the squared pixel-wise errors

    """
    stim_df = stim_df.query('scaling in [@scaling, None]')
    num_seeds = stim_df.groupby('image_name').seed.nunique().mean()
    if int(num_seeds) != num_seeds:
        raise Exception("not all images have same number of seeds!")
    errors = np.zeros((int(num_seeds), stim_df.image_name.nunique(),
                       *stim.shape[-2:]), dtype=np.float32)
    errors *= np.nan
    for i, (im, g) in enumerate(stim_df.groupby('image_name')):
        target_img = stim[g.query('scaling in [None]').index[0]]
        # convert to float in a piecemeal fashion (rather than all at once in
        # the beginning) to reduce memory load. Can't select the subset of
        # images we want either, because then indices no longer line up
        target_img = utils.convert_im_to_float(target_img)
        for j, (seed, h) in enumerate(g.groupby('seed')):
            if len(h.index) > 1:
                raise Exception(f"Got more than 1 image with seed {seed} and "
                                f"image name {im}")
            synth_img = utils.convert_im_to_float(stim[h.index[0]])
            errors[j, i] = np.square(synth_img - target_img)
    errors = np.nanmean(errors, 0)
    titles = [t.replace('_range-.05,.95_size-2048,2600', '')
              for t in stim_df.image_name.unique()]
    fig = pt.imshow([e for e in errors], zoom=.5, col_wrap=5,
                    title=sorted(titles))
    fig.suptitle(f'Pixelwise squared errors for scaling {scaling}, averaged across seeds\n',
                 va='bottom', fontsize=fig.axes[0].title.get_fontsize()*1.25)
    return fig, errors


def simulate_num_trials(params, row='critical_scaling_true', col='variable'):
    """Create figure summarizing num_trials simulations.

    Assumes only one true value of proportionality_factor (will still work if
    not true, just might not be as good-looking).

    Parameters
    ----------
    params : pd.DataFrame
        DataFrame containing results from several num_trials simulations

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid with the plot.

    """
    tmp = params.melt(value_vars=['critical_scaling_true', 'proportionality_factor_true'],
                      value_name='true_value')
    tmp['variable'] = tmp.variable.apply(lambda x: x.replace('_true', ''), )

    params = params.melt(['bootstrap_num', 'max_iter', 'lr', 'scheduler',
                          'num_trials', 'num_bootstraps', 'proportionality_factor_true',
                          'critical_scaling_true'],
                         value_vars=['critical_scaling', 'proportionality_factor'])
    params = params.merge(tmp, left_index=True, right_index=True, suffixes=(None, '_y'))
    params = params.drop('variable_y', 1)

    g = sns.FacetGrid(params, row=row, col=col, aspect=1.5, sharey=False)
    g.map_dataframe(plotting.scatter_ci_dist, 'num_trials', 'value')
    g.map(plt.plot, 'num_trials', 'true_value', color='k', linestyle='--')
    return g


def performance_plot(expt_df, col='image_name', row=None, hue=None, col_wrap=5,
                     ci=95, comparison='ref', curve_fit=False, **kwargs):
    """Plot performance as function of scaling.

    With default arguments, this is meant to show the results for all sessions
    and a single subject, showing the different images on each column. It
    should be flexible enough to handle other variants.

    Parameters
    ----------
    expt_df : pd.DataFrame
        DataFrame containing the results of at least one session for at least
        one subject, as created by a combination of
        `analysis.create_experiment_df` and `analysis.add_response_info`, then
        concatenating them across runs (and maybe sessions / subjects).
    col, row, hue : str or None, optional
        The variables in expt_df to facet along the columns, rows, and hues,
        respectively.
    col_wrap : int or None, optional
        If row is None, how many columns to have before wrapping to the next
        row. If this is not None and row is not None, will raise an Exception
    ci : int, optional
        What confidence interval to draw on the performance.
    comparison : {'ref', 'met'}, optional
        Whether this comparison is between metamers and reference images
        ('ref') or two metamers ('met').
    curve_fit : bool, optional
        If True, we'll fit the psychophysical curve (as given in
        mcmc.proportion_correct_curve) to the mean of each faceted subset of
        data and plot that. If False, we'll instead join the points.
    kwargs :
        passed to plotting.lineplot_like_pointplot

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    if hue is not None:
        kwargs.setdefault('palette', plotting.get_palette(hue, expt_df[hue].unique()))
    else:
        kwargs.setdefault('color', 'k')
    if curve_fit:
        kwargs['linestyle'] = ''
    with open(op.join(op.dirname(op.realpath(__file__)), '..', 'config.yml')) as f:
        config = yaml.safe_load(f)
    all_imgs = config['DEFAULT_METAMERS']['image_name']
    img_sets = config['PSYCHOPHYSICS']['IMAGE_SETS']
    img_order = (sorted(img_sets['all']) + sorted(img_sets['A']) +
                 sorted(img_sets['B']))
    img_order = [i.replace('symmetric_', '').replace('_range-.05,.95_size-2048,2600', '')
                 for i in img_order]
    if col == 'image_name':
        kwargs.setdefault('col_order', img_order)
    # while still gathering data, will not have all images in the
    # expt_df. Adding these blank lines gives us blank subplots in
    # the performance plot, so that each image is in the same place
    extra_ims = [i for i in all_imgs if i not in expt_df.image_name.unique()]
    expt_df = expt_df.copy().append(pd.DataFrame({'image_name': extra_ims}), True)
    assert expt_df.image_name.nunique() == 20, "Something went wrong, don't have all images!"
    # strip out the parts of the image name that are consistent across images
    expt_df.image_name = expt_df.image_name.apply(lambda x: x.replace('symmetric_', '').replace('_range-.05,.95_size-2048,2600', ''))

    g = plotting.lineplot_like_pointplot(expt_df, 'scaling',
                                         'hit_or_miss_numeric', ci=ci, col=col,
                                         row=row, hue=hue, col_wrap=col_wrap,
                                         **kwargs)
    if curve_fit:
        g.map_dataframe(plotting.fit_psychophysical_curve, 'scaling',
                        'hit_or_miss_numeric', pal=kwargs.get('palette', {}),
                        color=kwargs.get('color', 'k'))

    g.map_dataframe(plotting.map_flat_line, x='scaling', y=.5, colors='k')
    g.set_ylabels(f'Proportion correct (with {ci}% CI)')
    g.set_xlabels('Scaling')
    g.set(ylim=(.3, 1.05))
    g = plotting.title_experiment_summary_plots(g, expt_df, 'Performance',
                                                comparison)
    g.set_titles('{col_name}')
    # it's difficult to come up with good tick values. this finds a somewhat
    # reasonable number of ticks in reasonable locations, reducing the number
    # if the axis is small or the font is large
    xmin = np.round(expt_df.scaling.min() - .004, 2)
    xmax = np.round(expt_df.scaling.max(), 2)
    nticks = 12
    if kwargs.get('height', 10) < 6:
        nticks /= 2
    if mpl.rcParams['font.size'] > 15:
        nticks /= 2
        # don't want to overlap the labels on adjacent columns
        if col is not None:
            xmax -= (xmax-xmin)/10
    xtick_spacing = np.round((xmax - xmin) / (nticks-1), 2)
    xticks = [xmin+i*xtick_spacing for i in range(int(nticks+1))]
    for ax in g.axes.flatten():
        ax.yaxis.set_major_locator(mpl.ticker.FixedLocator([.5, 1]))
        ax.yaxis.set_minor_locator(mpl.ticker.FixedLocator([.4, .6, .7, .8, .9]))
        ax.xaxis.set_major_locator(mpl.ticker.FixedLocator(xticks))
    if col_wrap is not None:
        # these specific grabbing of axes works because we know we have 20 axes.
        # regardless of col_wrap, first axis will always have a ylabel and last one
        # will always have an xlabel
        ylabel = g.axes[0].get_ylabel()
        xlabel = g.axes[-1].get_xlabel()
        g.set(xlabel='', ylabel='')
        g.fig.subplots_adjust(hspace=.2, wspace=.1, top=1)
        g.axes[5].set_ylabel(ylabel, y=0, ha='center')
        g.axes[-3].set_xlabel(xlabel)
    return g


def run_length_plot(expt_df, col=None, row=None, hue=None, col_wrap=None,
                    comparison='ref'):
    """Plot run length.

    With default arguments, this is meant to show the results for all sessions
    and a single subject. It should be flexible enough to handle other
    variants.

    Parameters
    ----------
    expt_df : pd.DataFrame
        DataFrame containing the results of at least one session for at least
        one subject, as created by a combination of
        `analysis.create_experiment_df` and `analysis.add_response_info`, then
        concatenating them across runs (and maybe sessions / subjects).
    col, row, hue : str or None, optional
        The variables in expt_df to facet along the columns, rows, and hues,
        respectively.
    col_wrap : int or None, optional
        If row is None, how many columns to have before wrapping to the next
        row. If this is not None and row is not None, will raise an Exception
    comparison : {'ref', 'met'}, optional
        Whether this comparison is between metamers and reference images
        ('ref') or two metamers ('met').

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    expt_df['approximate_run_length_min'] = expt_df.approximate_run_length / 60
    g = sns.catplot(x='session_number', y='approximate_run_length_min',
                    kind='strip', col=col, row=row, hue=hue, col_wrap=col_wrap,
                    data=expt_df.drop_duplicates(['subject_name', 'session_number',
                                                  'run_number']))
    g.set_ylabels("Approximate run length (in minutes)")
    g = plotting.title_experiment_summary_plots(g, expt_df, 'Run length',
                                                comparison)
    return g


def compare_loss_and_performance_plot(expt_df, stim_df, col='scaling',
                                      row=None, hue='image_name', col_wrap=4):
    """Plot synthesis loss and behavioral performance against each other.

    Plots synthesis loss on the x-axis and proportion correct on the y-axis, to
    see if there's any relationship there. Hopefully, there's not (that is,
    synthesis progressed to the point where there's no real difference in
    image from more iterations)

    Currently, only works for comparison='ref' (comparison between reference
    and natural images), because we plot each seed separately and
    comparison='met' shows multiple seeds per trial.

    Parameters
    ----------
    expt_df : pd.DataFrame
        DataFrame containing the results of at least one session for at least
        one subject, as created by a combination of
        `analysis.create_experiment_df` and `analysis.add_response_info`, then
        concatenating them across runs (and maybe sessions / subjects).
    stim_df : pd.DataFrame
        The metamer information dataframe, as created by
        `stimuli.create_metamer_df`
    col, row, hue : str or None, optional
        The variables in expt_df to facet along the columns, rows, and hues,
        respectively.
    col_wrap : int or None, optional
        If row is None, how many columns to have before wrapping to the next
        row. If this is not None and row is not None, will raise an Exception

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    if expt_df.unique_seed.hasnans:
        raise Exception("There's a NaN in expt_df.unique_seed! This means that "
                        "this expt_df comes from a metamer_vs_metamer run. That "
                        "means there are multiple synthesized images per trial "
                        "and so this plot comparing performance and loss for a"
                        " single synthesized image doesn't make sense!")
    # need to get proportion_correct, not the raw responses, for this plot.
    # adding session_number here doesn't change results except to make sure
    # that the session_number column is preserved in the output (each session
    # contains all trials, all scaling for a given image)
    expt_df = analysis.summarize_expt(expt_df, ['session_number', 'scaling',
                                                'trial_type', 'unique_seed'])
    expt_df = expt_df.set_index(['subject_name', 'session_number', 'image_name',
                                 'scaling', 'unique_seed'])
    stim_df = stim_df.rename(columns={'seed': 'unique_seed'})
    stim_df = stim_df.set_index(['image_name', 'scaling',
                                 'unique_seed'])['loss'].dropna()
    expt_df = expt_df.merge(stim_df, left_index=True,
                            right_index=True,).reset_index()
    col_order, hue_order, row_order = None, None, None
    if col is not None:
        col_order = sorted(expt_df[col].unique())
    if row is not None:
        row_order = sorted(expt_df[row].unique())
    if hue is not None:
        hue_order = sorted(expt_df[hue].unique())
    g = sns.relplot(data=expt_df, x='loss', y='proportion_correct',
                    hue=hue, col=col, kind='scatter', col_wrap=col_wrap,
                    height=3, row=row, col_order=col_order,
                    hue_order=hue_order, row_order=row_order)
    g.set(xscale='log', xlim=plotting.get_log_ax_lims(expt_df.loss),
          ylabel='Proportion correct')
    g = plotting.title_experiment_summary_plots(g, expt_df,
                                                'Performance vs. synthesis loss',
                                                'ref', '\nHopefully no relationship here')
    return g


def posterior_predictive_check(inf_data, jitter_scaling=True,
                               facetgrid_kwargs={}, query_str=None):
    """Plot posterior predictive check.

    In order to make sure that our MCMC gave us a reasonable fit, we plot the
    posterior predictive responses and probability correct against the observed
    responses.

    Parameters
    ----------
    inf_data : arviz.InferenceData
        arviz InferenceData object (xarray-like) created by `run_inference`.
    jitter_scaling : bool or float, optional
        If not False, we jitter scaling values (so they don't get plotted on
        top of each other). If True, we jitter by 5e-3, else, the amount to
        jitter by. Will need to rework this for log axis.
    facetgrid_kwargs : dict, optional
        additional kwargs to pass to sns.FacetGrid. Cannot contain 'hue'.
    query_str : str or None, optional
        If not None, the string to query dataframe with to limit the plotted
        data (e.g., "distribution == 'posterior'").

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    if 'hue' in facetgrid_kwargs:
        raise Exception("Can't set hue!")
    df = mcmc.inf_data_to_df(inf_data, 'predictive', jitter_scaling, query_str)
    df = df.query('distribution!="prior_predictive"')
    g = sns.FacetGrid(df, height=5, **facetgrid_kwargs)
    g.map_dataframe(plotting.lineplot_like_pointplot, x='scaling',
                    y='responses', ax='map', hue='distribution', linestyle='')
    g.map_dataframe(sns.lineplot, x='scaling', y='probability_correct',
                    hue='distribution',
                    linewidth=mpl.rcParams['lines.linewidth']*1.8)
    g.add_legend()
    g.set(xlabel='scaling', ylabel='Proportion correct',)
    g.fig.suptitle('Posterior predictive check', va='bottom')
    return g


def parameter_distributions(inf_data, col='variable', hue='distribution',
                            clip=(0, 20), query_str=None, **kwargs):
    """Check prior and posterior parameter distributions for MCMC.

    Goal of this plot is to show that data mattered, i.e., that posteriors have
    shifted from priors.

    Parameters
    ----------
    inf_data : arviz.InferenceData
        arviz InferenceData object (xarray-like) created by `run_inference`.
    col, hue : str, optional
        variables to facet along. 'variable' gives the parameters from
        inf_data, other possible values are its coords
    clip : pair of numbers or list of such, optional
        Values to clip the evaluation of KDE along. See sns.kdeplot docstring
        for more details. Prior ends up including way larger values than
        posterior, so we clip to get a reasonable view
    query_str : str or None, optional
        If not None, the string to query dataframe with to limit the plotted
        data (e.g., "distribution == 'posterior'").
    kwargs :
        passed to sns.displot

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    df = mcmc.inf_data_to_df(inf_data, 'parameters', query_str=query_str)
    # when you have this many samples from the prior, sometimes you get weird
    # samples, way too large. since we're sampling some of the parameters in
    # log-space, this can lead to infinite values. to avoid this, we drop any
    # draws that have any parameter greater than 1e30 (max float32 is ~3.4e38)
    if (df.value > 1e30).any():
        gb = df[df.value > 1e30].groupby(['chain', 'draw', 'distribution'])
        to_drop = [n for n, _ in gb]
        df = df.set_index(['chain', 'draw', 'distribution'])
        df = df.drop(to_drop).reset_index()
    g = sns.displot(df, hue=hue, x='value', col=col, kind='kde', clip=clip,
                    facet_kws=dict(sharex='col', sharey=False),
                    **kwargs)
    return g


def mcmc_diagnostics_plot(inf_data):
    """Plot MCMC diagnostics.

    This plot contains the posterior distributions and sampling trace for all
    parameters (each chain showne), with r-hat and effective sample size (both
    diagnostic stats) on the plots.

    r-hat: ratio of average variance of samples within each chain to the
    variance of pooled samples across chains. If all chains have converged,
    this should be 1.

    effective sample size (ESS): computed, from autocorrelation, measures
    effective number of samples. different draws in a chain should be
    independent samples from the posterior, so they shouldn't be
    autocorrelated. therefore, this number should be large. if it's small,
    probably need more warmup steps and draws.

    Parameters
    ----------
    inf_data : arviz.InferenceData
        arviz InferenceData object (xarray-like) created by `run_inference`.

    Returns
    -------
    fig : plt.Figure
        matplotlib figure containing the plots.

    """
    axes = az.plot_trace(inf_data)
    rhat = az.rhat(inf_data.posterior)
    ess = az.ess(inf_data.posterior)
    for ax in axes:
        var = ax[0].get_title()
        ax[0].set_title(ax[0].get_title()+
                        f', mean r_hat={rhat[var].data.mean():.05f}')
        ax[1].set_title(ax[1].get_title()+
                        f', mean effective sample size={ess[var].data.mean():.02f}')
    fig = axes[0, 0].figure
    # want monospace so table prints correctly
    rhat = rhat.to_dataframe().reorder_levels(['trial_type', 'image_name', 'subject_name'])
    fig.text(1, 1, "rhat\n"+rhat.sort_index().to_markdown(),
             ha='left', va='top', family='monospace')
    ess = ess.to_dataframe().reorder_levels(['trial_type', 'image_name', 'subject_name'])
    fig.text(1, .5, "effective sample size\n"+ess.sort_index().to_markdown(),
             ha='left', va='top', family='monospace')
    fig.suptitle("Diagnostics plot for MCMC, showing distribution and sampling"
                 " trace for each parameter", va='baseline')
    return fig


def parameter_pairplot(inf_data, vars=None,
                       query_str="distribution=='posterior'", **kwargs):
    """Joint distributions of posterior parameter values.

    Parameters
    ----------
    inf_data : arviz.InferenceData
        arviz InferenceData object (xarray-like) created by `run_inference`.
    vars : list or None, optional
        List of strs giving the parameters to plot here. If None, will plot all.
    query_str : str or None, optional
        If not None, the string to query dataframe with to limit the plotted
        data (e.g., "distribution == 'posterior'"). Should almost certainly
        include that distribution selection to your query_str for this plot.

    kwargs :
        passed to sns.pairplot

    Returns
    -------
    g : sns.PairGrid
        sns PairGrid containing the plots.

    """
    df = mcmc.inf_data_to_df(inf_data, 'parameters', query_str=query_str)
    pivot_idx = [c for c in df.columns if c not in ['value', 'variable']]
    df = df.pivot_table('value', pivot_idx, 'variable')
    def key_func(x):
        # want these to be first
        if 'log' in x:
            return '__' + x
        # then these
        elif 'global' in x:
            return '_' + x
        # and this last
        elif x == 'pi_l':
            return 'z' + x
        else:
            return x
    if vars is None:
        vars = sorted(df.columns, key=key_func)
    g = sns.pairplot(df.reset_index(), vars=vars, corner=True, diag_kind='kde',
                     kind='kde', diag_kws={'cut': 0}, **kwargs)
    g.fig.suptitle('Joint distributions of model parameters')
    return g


def psychophysical_parameters(inf_data, x='image_name', y='value',
                              hue='subject_name', col='parameter',
                              row='trial_type',
                              query_str="distribution=='posterior'", height=5,
                              x_dodge=.1, hdi=.95, rotate_xticklabels=False,
                              **kwargs):
    """Show psychophysical curve parameters.

    This plots the psychophysical curve parameters for all full curves we can
    draw. That is, we combine the effects of our model and show the values for
    each trial type, image, and subject.


    Parameters
    ----------
    inf_data : arviz.InferenceData
        arviz InferenceData object (xarray-like) created by `run_inference`.
    x, y, hue, col, row : str, optional
        variables to plot on axes or facet along. 'value' is the value of the
        parameters, 'parameter' is the identity of the parameter (e.g., 's0',
        'a0'), all other are the coords of inf_data
    query_str : str or None, optional
        If not None, the string to query dataframe with to limit the plotted
        data (e.g., "distribution == 'posterior'").
        posterior, so we clip to get a reasonable view
    height : float, optional
        Height of the facets
    x_dodge : float, None, or bool, optional
        to improve visibility with many points that have the same x-values (or
        are categorical), we can dodge the data along the x-axis,
        deterministically shifting it. If a float, x_dodge is the amount we
        shift each level of hue by; if None, we don't dodge at all; if True, we
        dodge as if x_dodge=.01
    hdi : float, optional
        The width of the HDI to draw (in range (0, 1]). See docstring of
        fov.mcmc.inf_data_to_df for more details.
    rotate_xticklabels : bool or int, optional
        whether to rotate the x-axis labels or not. if True, we rotate
        by 25 degrees. if an int, we rotate by that many degrees. if
        False, we don't rotate.
    kwargs :
        passed to sns.FacetGrid

    Returns
    -------
    g : sns.FacetGrid
        FacetGrid containing the figure.

    """
    kwargs.setdefault('sharey', False)
    df = mcmc.inf_data_to_df(inf_data, 'psychophysical curve parameters',
                             query_str=query_str, hdi=hdi)

    g = sns.FacetGrid(hue=hue, col=col, row=row, data=df, height=height,
                      **kwargs)
    g.map_dataframe(plotting.scatter_ci_dist, y=y, x=x, x_dodge=x_dodge,
                    all_labels=list(df[hue].unique()), like_pointplot=True,
                    ci='hdi')
    g.add_legend()
    g.set_xlabels(x)
    g.set_ylabels(y)
    g.fig.suptitle("Psychophysical curve parameter values\n", va='bottom')
    if rotate_xticklabels:
        if rotate_xticklabels is True:
            rotate_xticklabels = 25
        for ax in g.axes.flatten():
            labels = ax.get_xticklabels()
            if labels:
                ax.set_xticklabels(labels, rotation=rotate_xticklabels,
                                   ha='right')
    return g


def ref_image_summary(stim, stim_df, zoom=.125):
    """Display grid of reference images used for metamer synthesis.

    We gamma-correct the reference images before display and title each with
    the simple name (e.g., "llama", "troop")

    Parameters
    ----------
    stim : np.ndarray
        The array of metamers we want to check, should correspond to stim_df
    stim_df : pd.DataFrame
        The metamer information dataframe, as created by
        stimuli.create_metamer_df
    zoom : float or int, optional
        How to zoom the images. Must result in an integer number of pixels

    Returns
    -------
    fig : plt.Figure
        Figure containing the images.

    """
    ref_ims = stim_df.fillna('None').query("model=='None'").image_name
    ref_ims = ref_ims.apply(lambda x: x.replace('symmetric_', '').replace('_range-.05,.95_size-2048,2600', ''))
    with open(op.join(op.dirname(op.realpath(__file__)), '..', 'config.yml')) as f:
        img_sets = yaml.safe_load(f)['PSYCHOPHYSICS']['IMAGE_SETS']
    img_order = (sorted(img_sets['all']) + sorted(img_sets['A']) +
                 sorted(img_sets['B']))
    img_order = [i.replace('symmetric_', '').replace('_range-.05,.95_size-2048,2600', '')
                 for i in img_order]
    ref_ims = ref_ims.sort_values(key=lambda x: [img_order.index(i) for i in x])
    refs = stim[ref_ims.index]

    ax_size = np.array([2048, 2600]) * zoom
    fig = pt.tools.display.make_figure(4, 5, ax_size, vert_pct=.9)
    for ax, im, t in zip(fig.axes, refs, ref_ims.values):
        # gamma-correct the image
        ax.imshow((im/255)**(1/2.2), vmin=0, vmax=1, cmap='gray')
        ax.set_title(t)
    return fig
