import os
import re
import imageio
import time
import os.path as op
import numpy as np
from glob import glob
from plenoptic.simulate import pooling

configfile:
    "config.yml"
if not os.path.isdir(config["DATA_DIR"]):
    raise Exception("Cannot find the dataset at %s" % config["DATA_DIR"])
if os.system("module list") == 0:
    # then we're on the cluster
    ON_CLUSTER = True
    # need ffmpeg and our conda environment
    shell.prefix(". /share/apps/anaconda3/5.3.1/etc/profile.d/conda.sh; conda activate metamers; "
                 "module load ffmpeg/intel/3.2.2; ")
else:
    ON_CLUSTER = False
wildcard_constraints:
    num="[0-9]+",
    pad_mode="constant|symmetric",
    period="[0-9]+",
    size="[0-9,]+",
    bits="[0-9]+",
    img_preproc="full|cone|cone_full",
    preproc_image_name="azulejos|tiles|market|flower",
    pixabay_image_name="trees|sheep|refuge|japan|street",
    preproc="|_degamma|_degamma_cone|_cone|degamma|degamma_cone|cone"
ruleorder:
    preproc_image > crop_image > generate_image > degamma_image > prep_pixabay


LINEAR_IMAGES = ['azulejos', 'tiles', 'market', 'flower']
MODELS = ['RGC_cone-1.0_gaussian', 'V1_cone-1.0_norm_s6_gaussian']
IMAGES = ['azulejos_cone_full_size-2048,3528', 'tiles_cone_full_size-2048,3528',
          'market_cone_full_size-2048,3528', 'flower_cone_full_size-2048,3528']
METAMER_TEMPLATE_PATH = op.join(config['DATA_DIR'], 'metamers', '{model_name}', '{image_name}',
                                'scaling-{scaling}', 'opt-{optimizer}', 'fr-{fract_removed}_lc-'
                                '{loss_fract}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                                'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-'
                                '{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_'
                                'metamer.png')
OUTPUT_TEMPLATE_PATH = op.join(config['DATA_DIR'], 'metamers_display', '{model_name}', '{image_name}',
                               'scaling-{scaling}', 'opt-{optimizer}', 'fr-{fract_removed}_lc-'
                               '{loss_fract}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                               'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-'
                               '{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_'
                               'metamer.png')
REF_IMAGE_TEMPLATE_PATH = op.join(config['DATA_DIR'], 'ref_images', '{image_name}.png')
SUBJECTS = ['sub-%02d' % i for i in range(1, 31)]
SESSIONS = [0, 1, 2]


def get_all_metamers(min_idx=0, max_idx=-1, model_name=None):
    rgc_scaling = [.01, .013, .017, .021, .027, .035, .045, .058, .075]
    # rgc_gpu_dict = {.01: 0, .013: 0, .017: 4, .021: 4, .027: 3, .035: 3}
    rgc_metamers = [OUTPUT_TEMPLATE_PATH.format(model_name=MODELS[0], image_name=i, scaling=sc,
                                                optimizer='Adam', fract_removed=0, loss_fract=1,
                                                coarse_to_fine=0, seed=s, init_type='white',
                                                learning_rate=1, min_ecc=3.71, max_ecc=41,
                                                max_iter=750, loss_thresh=1e-8, gpu=0,
                                                clamp='clamp2', clamp_each_iter=True)
                    for sc in rgc_scaling for i in IMAGES for s in range(3)]
    v1_scaling = [.075, .095, .12, .15, .19, .25, .31, .39, .5]
    v1_metamers = [OUTPUT_TEMPLATE_PATH.format(model_name=MODELS[1], image_name=i, scaling=sc,
                                               optimizer='Adam', fract_removed=0, loss_fract=1,
                                               coarse_to_fine=1e-2, seed=s, init_type='white',
                                               learning_rate={.075: 1}.get(sc, .1), min_ecc=.5,
                                               max_ecc=41, max_iter={.075: 7500}.get(sc, 5000),
                                               loss_thresh=1e-8, gpu=1, clamp='clamp2',
                                               clamp_each_iter=True)
                    for sc in v1_scaling for i in IMAGES for s in range(3)]
    if model_name is None:
        all_metamers = rgc_metamers + v1_metamers
    elif model_name == MODELS[0]:
        all_metamers = rgc_metamers
    elif model_name == MODELS[1]:
        all_metamers = v1_metamers
    else:
        raise Exception("model_name must be one of %s" % MODELS)
    # we use -1 as a dummy value, ignoring it
    if max_idx != -1:
        all_metamers = all_metamers[:max_idx]
    return all_metamers[min_idx:]


rule all_refs:
    input:
        [REF_IMAGE_TEMPLATE_PATH.format(image_name=i) for i in IMAGES]


rule prep_pixabay:
    input:
        # all the pixabay images have a string of integers after the
        # name, which we want to ignore
        lambda wildcards: glob(op.join(config["PIXABAY_DIR"], '{pixabay_image_name}-*.jpg').format(**wildcards))
    output:
        op.join(config["DATA_DIR"], 'ref_images', '{pixabay_image_name}.png')
    log:
        op.join(config["DATA_DIR"], 'logs', 'ref_images', '{pixabay_image_name}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'ref_images', '{pixabay_image_name}_benchmark.txt')
    run:
        import imageio
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0], as_gray=True)
                curr_shape = np.array(im.shape)
                target_shape = np.array([2048, 3528])
                crop_amt = curr_shape - target_shape
                cropped_im = im[crop_amt[0]//2:-crop_amt[0]//2, crop_amt[1]//2:-crop_amt[1]//2]
                imageio.imwrite(output[0], cropped_im)


# most of our input images are jpegs, which have already had a gamma
# correction applied to them. since we'll be displaying them on a linear
# display, we want to remove this correction (see
# https://www.cambridgeincolour.com/tutorials/gamma-correction.htm for
# an explanation)
rule degamma_image:
    input:
        op.join(config['DATA_DIR'], 'ref_images', '{image_name}.png')
    output:
        op.join(config['DATA_DIR'], 'ref_images', '{image_name}-degamma-{bits}.png')
    log:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}-degamma-{bits}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}-degamma-{bits}'
                '_benchmark.txt')
    run:
        import imageio
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0], as_gray=True)
                # when loaded in, the range of this will be 0 to 255, we
                # want to convert it to 0 to 1
                im = im / 255
                # 1/2.2 is the standard encoding gamma for jpegs, so we
                # raise this to its reciprocal, 2.2, in order to reverse
                # it
                im = im**2.2
                dtype = eval('np.uint%s' % wildcards.bits)
                imageio.imwrite(output[0], (im * np.iinfo(dtype).max).astype(dtype))


rule demosaic_image:
    input:
        op.join(config['DATA_DIR'], 'raw_images', '{image_name}.NEF')
    output:
        op.join(config['DATA_DIR'], 'ref_images', '{image_name}.tiff')
    log:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}_benchmark.txt')
    params:
        tiff_file = lambda wildcards, input: input[0].replace('NEF', 'tiff')
    shell:
        "dcraw -v -4 -q 3 -T {input}; "
        "mv {params.tiff_file} {output}"


rule crop_image:
    input:
        op.join(config['DATA_DIR'], 'ref_images', '{image_name}.tiff')
    output:
        op.join(config['DATA_DIR'], 'ref_images', '{image_name}_size-{size}.png')
    log:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}_size-{size}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_name}_size-{size}_benchmark.txt')
    run:
        import imageio
        import contextlib
        from skimage import color
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0])
                curr_shape = np.array(im.shape)[:2]
                target_shape = [int(i) for i in wildcards.size.split(',')]
                if len(target_shape) == 1:
                    target_shape = 2* target_shape
                target_shape = np.array(target_shape)
                crop_amt = curr_shape - target_shape
                cropped_im = im[crop_amt[0]//2:-crop_amt[0]//2, crop_amt[1]//2:-crop_amt[1]//2]
                cropped_im = color.rgb2gray(cropped_im)
                imageio.imwrite(output[0], (cropped_im * np.iinfo(np.uint16).max).astype(np.uint16))
                # tiffs can't be read in using the as_gray arg, so we
                # save it as a png, and then read it back in as_gray and
                # save it back out
                cropped_im = imageio.imread(output[0], as_gray=True)
                imageio.imwrite(output[0], cropped_im.astype(np.uint16))


rule preproc_image:
    input:
        op.join(config['DATA_DIR'], 'ref_images', '{preproc_image_name}_size-{size}.png')
    output:
        op.join(config['DATA_DIR'], 'ref_images_preproc', '{preproc_image_name}_{img_preproc}_size-{size}.png')
    log:
        op.join(config['DATA_DIR'], 'logs', 'ref_image_preproc',
                '{preproc_image_name}_{img_preproc}_size-{size}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'ref_image_preproc',
                '{preproc_image_name}_{img_preproc}_size-{size}_benchmark.txt')
    run:
        import imageio
        import contextlib
        import numpy as np
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0])
                dtype = im.dtype
                im = np.array(im, dtype=np.float32)
                print("Original image has dtype %s" % dtype)
                if 'full' in wildcards.img_preproc:
                    print("Setting image to use full dynamic range")
                    # set the minimum value to 0
                    im = im - im.min()
                    # set the maximum value to 1
                    im = im / im.max()
                else:
                    print("Image will *not* use full dynamic range")
                    im = im / np.iinfo(dtype).max
                if 'cone' in wildcards.img_preproc:
                    print("Raising image to the 1/3, to approximate cone response")
                    im = im ** (1/3)
                # always save it as 16 bit
                print("Saving as 16 bit")
                im = im * np.iinfo(np.uint16).max
                imageio.imwrite(output[0], im.astype(np.uint16))


rule pad_image:
    input:
        op.join(config["DATA_DIR"], 'ref_images', '{image_name}.{ext}')
    output:
        op.join(config["DATA_DIR"], 'ref_images', '{image_name}_{pad_mode}.{ext}')
    log:
        op.join(config["DATA_DIR"], 'logs', 'ref_images', '{image_name}_{pad_mode}-{ext}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'ref_images', '{image_name}_{pad_mode}-{ext}_benchmark.txt')
    run:
        import foveated_metamers as met
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                met.stimuli.pad_image(input[0], wildcards.pad_mode, output[0])


rule generate_image:
    output:
        op.join(config['DATA_DIR'], 'ref_images', '{image_type}_period-{period}_size-{size}.png')
    log:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_type}_period-{period}_size-'
                '{size}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'ref_images', '{image_type}_period-{period}_size-'
                '{size}_benchmark.txt')
    run:
        import foveated_metamers as met
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                met.stimuli.create_image(wildcards.image_type, int(wildcards.size), output[0],
                                         int(wildcards.period))

rule preproc_textures:
    input:
        config['TEXTURE_DIR']
    output:
        directory(config['TEXTURE_DIR'] + "_{preproc}")
    log:
        op.join(config['DATA_DIR'], 'logs', '{preproc}_textures.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', '{preproc}_textures_benchmark.txt')
    run:
        import imageio
        import contextlib
        from glob import glob
        import os.path as op
        import os
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                os.makedirs(output[0])
                for i in glob(op.join(input[0], '*.jpg')):
                    im = imageio.imread(i, as_gray=True)
                    # when loaded in, the range of this will be 0 to 255, we
                    # want to convert it to 0 to 1
                    im = im / 255
                    if 'degamma' in wildcards.preproc:
                        # 1/2.2 is the standard encoding gamma for jpegs, so we
                        # raise this to its reciprocal, 2.2, in order to reverse
                        # it
                        im = im ** 2.2
                    if 'cone' in wildcards.preproc:
                        im = im ** (1/3)
                    # save as a 16 bit png
                    im = (im * np.iinfo(np.uint16).max).astype(np.uint16)
                    imageio.imwrite(op.join(output[0], op.split(i)[-1].replace('jpg', 'png')), im)


rule gen_norm_stats:
    input:
        config['TEXTURE_DIR'] + "{preproc}"
    output:
        # here V1 and texture could be considered wildcards, but they're
        # the only we're doing this for now
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm_stats-'
                '{num}.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm_'
                'stats-{num}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm_'
                'stats-{num}_benchmark.txt')
    params:
        index = lambda wildcards: (int(wildcards.num) * 100, (int(wildcards.num)+1) * 100)
    run:
        import plenoptic as po
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                # scaling doesn't matter here
                if 'gamma' == wildcards.cone:
                    cone_power = 1/2.2
                elif 'phys' == wildcards.cone:
                    cone_power = 1/3
                else:
                    cone_power = float(wildcards.cone)
                v1 = po.simul.PrimaryVisualCortex(1, (512, 512), half_octave_pyramid=True,
                                                  num_scales=6, cone_power=cone_power,
                                                  include_highpass=True)
                po.simul.non_linearities.generate_norm_stats(v1, input[0], output[0], (512, 512),
                                                             index=params.index)


# we need to generate the stats in blocks, and then want to re-combine them
rule combine_norm_stats:
    input:
        lambda wildcards: [op.join(config['DATA_DIR'], 'norm_stats', 'V1_cone-{cone}_texture'
                                   '{preproc}_norm_stats-{num}.pt').format(num=i, **wildcards)
                           for i in range(9)]
    output:
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm_stats.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm_'
                'stats.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_cone-{cone}_texture{preproc}_norm'
                '_stats_benchmark.txt')
    run:
        import torch
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                combined_stats = {}
                to_combine = [torch.load(i) for i in input]
                for k, v in to_combine[0].items():
                    if isinstance(v, dict):
                        d = {}
                        for l in v:
                            s = []
                            for i in to_combine:
                                s.append(i[k][l])
                            d[l] = torch.cat(s, 0)
                        combined_stats[k] = d
                    else:
                        s = []
                        for i in to_combine:
                            s.append(i[k])
                        combined_stats[k] = torch.cat(s, 0)
                torch.save(combined_stats, output[0])


rule cache_windows:
    output:
        op.join(config["DATA_DIR"], 'windows_cache', 'scaling-{scaling}_size-{size}_e0-{min_ecc}_'
                'em-{max_ecc}_w-{t_width}_{window_type}.pt')
    log:
        op.join(config["DATA_DIR"], 'logs', 'windows_cache', 'scaling-{scaling}_size-{size}_e0-'
                '{min_ecc}_em-{max_ecc}_w-{t_width}_{window_type}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'windows_cache', 'scaling-{scaling}_size-{size}_e0-'
                '{min_ecc}_em-{max_ecc}_w-{t_width}_{window_type}.benchmark.txt')
    run:
        import contextlib
        import plenoptic as po
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                img_size = [int(i) for i in wildcards.size.split(',')]
                if wildcards.window_type == 'cosine':
                    t_width = float(wildcards.t_width)
                    std_dev = None
                elif wildcards.window_type == 'gaussian':
                    std_dev = float(wildcards.t_width)
                    t_width = None
                po.simul.PoolingWindows(float(wildcards.scaling), img_size, float(wildcards.min_ecc),
                                        float(wildcards.max_ecc), cache_dir=op.dirname(output[0]),
                                        transition_region_width=t_width, std_dev=std_dev,
                                        window_type=wildcards.window_type)


def get_norm_dict(wildcards):
    if 'norm' in wildcards.model_name and 'V1' in wildcards.model_name:
        preproc = ''
        # lienar images should also use the degamma'd textures
        if 'degamma' in wildcards.image_name or any([i in wildcards.image_name for i in LINEAR_IMAGES]):
            preproc += '_degamma'
        if 'cone' in wildcards.image_name:
            preproc += '_cone'
        try:
            if 'cone-gamma' in wildcards.model_name:
                cone_power = 'gamma'
            elif 'cone-phys' in wildcards.model_name:
                cone_power = 'phys'
            else:
                cone_power = float(re.findall('cone-([.0-9]+)', wildcards.model_name)[0])
        except IndexError:
            # default is 1, linear response
            cone_power = 1
        return op.join(config['DATA_DIR'], 'norm_stats', 'V1_cone-%s_texture%s_norm_stats.pt'
                       % (cone_power, preproc))
    else:
        return []


def get_windows(wildcards):
    r"""determine the cached window path for the specified model
    """
    window_template = op.join(config["DATA_DIR"], 'windows_cache', 'scaling-{scaling}_size-{size}'
                              '_e0-{min_ecc:.03f}_em-{max_ecc:.01f}_w-{t_width}_{window_type}.pt')
    if 'size-' in wildcards.image_name:
        im_shape = wildcards.image_name[wildcards.image_name.index('size-') + len('size-'):]
        im_shape = im_shape.replace('.png', '')
        im_shape = [int(i) for i in im_shape.split(',')]
    else:
        try:
            im = imageio.imread(REF_IMAGE_TEMPLATE_PATH.format(image_name=wildcards.image_name))
            im_shape = im.shape
        except FileNotFoundError:
            raise Exception("Can't find input image %s or infer its shape, so don't know what "
                            "windows to cache!" %
                            REF_IMAGE_TEMPLATE_PATH.format(image_name=wildcards.image_name))
    if 'cosine' in wildcards.model_name:
        window_type = 'cosine'
        t_width = 1.0
    elif 'gaussian' in wildcards.model_name:
        window_type = 'gaussian'
        t_width = 1.0
    if wildcards.model_name.startswith("RGC"):
        size = ','.join([str(i) for i in im_shape])
        return window_template.format(scaling=wildcards.scaling, size=size,
                                      max_ecc=float(wildcards.max_ecc), t_width=t_width,
                                      min_ecc=float(wildcards.min_ecc), window_type=window_type,)
    elif wildcards.model_name.startswith('V1'):
        windows = []
        # need them for every scale
        try:
            num_scales = int(re.findall('s([0-9]+)', wildcards.model_name)[0])
        except (IndexError, ValueError):
            num_scales = 4
        for i in range(num_scales):
            output_size = ','.join([str(int(np.ceil(j / 2**i))) for j in im_shape])
            min_ecc, _ = pooling.calc_min_eccentricity(float(wildcards.scaling),
                                                       [np.ceil(j / 2**i) for j in im_shape],
                                                       float(wildcards.max_ecc))
            # don't do this for the lowest scale
            if i > 0 and min_ecc > float(wildcards.min_ecc):
                # this makes sure that whatever that third decimal place
                # is, we're always one above it. e.g., if min_ecc was
                # 1.3442, we want to use 1.345, and this will ensure
                # that
                min_ecc *= 1e3
                min_ecc -= min_ecc % 1
                min_ecc = (min_ecc+1) / 1e3
            else:
                min_ecc = float(wildcards.min_ecc)
            windows.append(window_template.format(scaling=wildcards.scaling, size=output_size,
                                                  max_ecc=float(wildcards.max_ecc),
                                                  min_ecc=min_ecc, t_width=t_width,
                                                  window_type=window_type))
        return windows


def get_batches(wildcards):
    if len(wildcards.gpu.split(':')) > 1:
        return int(wildcards.gpu.split(':')[1])
    else:
        return 1


def get_ref_image(wildcards):
    r"""get ref image
    """
    if 'full' in wildcards.image_name or 'cone' in wildcards.image_name:
        template = REF_IMAGE_TEMPLATE_PATH.replace('ref_images', 'ref_images_preproc')
    else:
        template = REF_IMAGE_TEMPLATE_PATH
    return template.format(image_name=wildcards.image_name)


rule create_metamers:
    input:
        ref_image = get_ref_image,
        windows = get_windows,
        norm_dict = get_norm_dict,
    output:
        METAMER_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        METAMER_TEMPLATE_PATH,
    log:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}', 'seed-{seed}_init-{init_type}_'
                'lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}'
                '_gpu-{gpu}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}', 'seed-{seed}_init-{init_type}_'
                'lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}'
                '_gpu-{gpu}_benchmark.txt')
    resources:
        gpu = lambda wildcards: int(wildcards.gpu.split(':')[0]),
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
        num_batches = get_batches,
    run:
        import foveated_metamers as met
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                # bool('False') == True, so we do this to avoid that
                # situation
                if wildcards.clamp_each_iter == 'True':
                    clamp_each_iter = True
                elif wildcards.clamp_each_iter == 'False':
                    clamp_each_iter = False
                if wildcards.init_type not in ['white', 'blue', 'pink', 'gray']:
                    init_type = REF_IMAGE_TEMPLATE_PATH.format(image_name=wildcards.init_type)
                else:
                    init_type = wildcards.init_type
                met.create_metamers.main(wildcards.model_name, float(wildcards.scaling),
                                         input.ref_image, int(wildcards.seed), float(wildcards.min_ecc),
                                         float(wildcards.max_ecc), float(wildcards.learning_rate),
                                         int(wildcards.max_iter), float(wildcards.loss_thresh),
                                         output[0], init_type, resources.gpu>0,
                                         params.cache_dir, input.norm_dict, resources.gpu,
                                         wildcards.optimizer, float(wildcards.fract_removed),
                                         float(wildcards.loss_fract),
                                         float(wildcards.coarse_to_fine), int(params.num_batches),
                                         wildcards.clamp, clamp_each_iter)


rule postproc_metamers:
    input:
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        METAMER_TEMPLATE_PATH,
    output:
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        OUTPUT_TEMPLATE_PATH,
    log:
        op.join(config["DATA_DIR"], 'logs', 'postproc_metamers', '{model_name}',
                '{image_name}', 'scaling-{scaling}', 'opt-{optimizer}',
                'fr-{fract_removed}_lc-{loss_fract}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-'
                '{max_iter}_thresh-{loss_thresh}_gpu-{gpu}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'postproc_metamers', '{model_name}',
                '{image_name}', 'scaling-{scaling}', 'opt-{optimizer}',
                'fr-{fract_removed}_lc-{loss_fract}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-'
                '{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_benchmark.txt')
    run:
        import foveated_metamers as met
        import contextlib
        import numpy as np
        import shutil
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                for i, f in enumerate(input):
                    if ('cone' in wildcards.image_name and
                        (f.endswith('metamer.png') or f.endswith('metamer-16.png'))):
                        print("De-conifying image %s, saving at %s" % (f, output[i]))
                        im = imageio.imread(f)
                        dtype = im.dtype
                        print("Retaining image dtype %s" % dtype)
                        im = np.array(im, dtype=np.float32) / np.iinfo(dtype).max
                        im = im ** 3
                        im = im * np.iinfo(dtype).max
                        imageio.imwrite(output[i], im.astype(dtype))
                    else:
                        print("Copy file %s to %s" % (f, output[i]))
                        shutil.copy(f, output[i])


rule dummy_metamer_gen:
    input:
        lambda wildcards: get_all_metamers(int(wildcards.min_idx), int(wildcards.max_idx),
                                           wildcards.model_name),
    output:
        op.join(config['DATA_DIR'], 'metamers', 'dummy_{model_name}_{min_idx}_{max_idx}.txt')
    shell:
        "touch {output}"


rule collect_metamers:
    input:
        lambda wildcards: get_all_metamers(**wildcards),
    output:
        # we collect across image_name and scaling, and don't care about
        # learning_rate, max_iter, loss_thresh
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli.npy'),
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description.csv'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'stimuli.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'stimuli_benchmark.txt'),
    run:
        import foveated_metamers as met
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                met.stimuli.collect_images(input, output[0])
                met.stimuli.create_metamer_df(input, output[1])


rule generate_experiment_idx:
    input:
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description.csv'),
    output:
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', '{subject}_idx_sess-{num}.npy'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', '{subject}_idx_sess-{num}'
                '.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', '{subject}_idx_sess-{num}'
                '_benchmark.txt'),
    params:
        # the number from subject will be a number from 1 to 30, which
        # we multiply by 10 in order to get the tens/hundreds place, and
        # the session number will be between 0 and 2, which we use for
        # the ones place. we use the same seed for different model
        # stimuli, since those will be completely different sets of
        # images.
        seed = lambda wildcards: 10*int(wildcards.subject.replace('sub-', '')) + int(wildcards.num)
    run:
        import foveated_metamers as met
        import pandas as pd
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                met.stimuli.generate_indices(pd.read_csv(input[0]), params.seed, output[0])


rule gen_all_idx:
    input:
        [op.join(config["DATA_DIR"], 'stimuli', '{model_name}', '{subject}_idx_sess-'
                 '{num}.npy').format(model_name='RGC', subject=s, num=n)
         for s in SUBJECTS for n in SESSIONS],
        [op.join(config["DATA_DIR"], 'stimuli', '{model_name}', '{subject}_idx_sess-'
                 '{num}.npy').format(model_name='V1-norm-s6', subject=s, num=n)
         for s in SUBJECTS for n in SESSIONS]
