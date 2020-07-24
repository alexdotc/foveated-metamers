import os
import re
import imageio
import time
import os.path as op
import numpy as np
from glob import glob
from plenoptic.simulate import pooling
from foveated_metamers import utils

configfile:
    "config.yml"
if not op.isdir(config["DATA_DIR"]):
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
    img_preproc="full|cone|cone_full|degamma_cone|gamma-corrected|gamma-corrected_full|range-[,.0-9]+|gamma-corrected_range-[,.0-9]+",
    preproc_image_name="azulejos|tiles|market|flower|einstein",
    preproc="|_degamma|_degamma_cone|_cone|degamma|degamma_cone|cone",
    gpu="0|1",
ruleorder:
    collect_metamers_example > collect_metamers > demosaic_image > preproc_image > crop_image > generate_image > degamma_image


LINEAR_IMAGES = config['IMAGE_NAME']['ref_image']
MODELS = [config[i]['model_name'] for i in ['RGC', 'V1']]
IMAGES = config['DEFAULT_METAMERS']['image_name']
# this is ugly, but it's easiest way to just replace the one format
# target while leaving the others alone
REF_IMAGE_TEMPLATE_PATH = config['REF_IMAGE_TEMPLATE_PATH'].replace("{DATA_DIR}/", config['DATA_DIR'])
# the regex here removes all string formatting codes from the string,
# since Snakemake doesn't like them
METAMER_TEMPLATE_PATH = re.sub(":.*?}", "}", config['METAMER_TEMPLATE_PATH'].replace("{DATA_DIR}/", config['DATA_DIR']))
OUTPUT_TEMPLATE_PATH = METAMER_TEMPLATE_PATH.replace('metamers/{model_name}',
                                                     'metamers_display/{model_name}')
CONTINUE_TEMPLATE_PATH = (METAMER_TEMPLATE_PATH.replace('metamers/{model_name}', 'metamers_continue/{model_name}')
                          .replace("{clamp_each_iter}/", "{clamp_each_iter}/attempt-{num}_iter-{extra_iter}"))
TEXTURE_DIR = config['TEXTURE_DIR']
if TEXTURE_DIR.endswith(os.sep) or TEXTURE_DIR.endswith('/'):
    TEXTURE_DIR = TEXTURE_DIR[:-1]


# quick rule to check that there are GPUs available and the environment
# has been set up correctly.
rule test_setup:
    input:
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[0],
                                     image_name='einstein_degamma_cone_size-256,256',
                                     scaling=.1, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     coarse_to_fine=False, seed=0, init_type='white',
                                     learning_rate=1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=0,
                                     clamp='clamp', clamp_each_iter=True, loss='l2',
                                     loss_change_thresh=.1),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[1],
                                     image_name='einstein_degamma_cone_size-256,256',
                                     scaling=.5, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     loss_change_thresh=0.01, seed=0, init_type='white',
                                     learning_rate=.1, min_ecc=.5, max_ecc=15, max_iter=100,
                                     loss_thresh=1e-8, gpu=0, coarse_to_fine='together',
                                     clamp='clamp', clamp_each_iter=True, loss='l2'),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[0],
                                     image_name='einstein_degamma_cone_size-256,256',
                                     scaling=.1, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     coarse_to_fine=False, seed=0, init_type='white',
                                     learning_rate=1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=1,
                                     clamp='clamp', clamp_each_iter=True, loss='l2',
                                     loss_change_thresh=.1),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[1],
                                     image_name='einstein_degamma_cone_size-256,256',
                                     scaling=.5, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     loss_change_thresh=0.01, seed=0, init_type='white',
                                     learning_rate=.1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=1, clamp='clamp',
                                     clamp_each_iter=True, loss='l2', coarse_to_fine='together'),
    output:
        directory(op.join(config['DATA_DIR'], 'test_setup', MODELS[0], 'einstein')),
        directory(op.join(config['DATA_DIR'], 'test_setup', MODELS[1], 'einstein'))
    log:
        op.join(config['DATA_DIR'], 'logs', 'test_setup.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'test_setup_benchmark.txt')
    run:
        import contextlib
        import shutil
        import os.path as op
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                print("Copying outputs from %s to %s" % (op.dirname(input[0]), output[0]))
                shutil.copytree(op.dirname(input[0]), output[0])
                print("Copying outputs from %s to %s" % (op.dirname(input[1]), output[1]))
                shutil.copytree(op.dirname(input[1]), output[1])


rule all_refs:
    input:
        [op.join(config['DATA_DIR'], 'ref_images_preproc', i + '.png') for i in IMAGES],
        [op.join(config['DATA_DIR'], 'ref_images_preproc', i.replace('cone_', '') + '.png')
         for i in IMAGES],


# for this project, our input images are linear images, but if you want
# to run this process on standard images, they have had a gamma
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
        import foveated_metamers as met
        from skimage import color
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0])
                # when loaded in, the range of this will be 0 to 255, we
                # want to convert it to 0 to 1
                im = met.utils.convert_im_to_float(im)
                # convert to grayscale
                im = color.rgb2gray(im)
                # 1/2.2 is the standard encoding gamma for jpegs, so we
                # raise this to its reciprocal, 2.2, in order to reverse
                # it
                im = im**2.2
                dtype = eval('np.uint%s' % wildcards.bits)
                imageio.imwrite(output[0], met.utils.convert_im_to_int(im, dtype))


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
        import foveated_metamers as met
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
                imageio.imwrite(output[0], met.utils.convert_im_to_int(cropped_im, np.uint16))
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
        import foveated_metamers as met
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
                elif 'range' in wildcards.img_preproc:
                    a, b = re.findall('range-([.0-9]+),([.0-9]+)', wildcards.img_preproc)[0]
                    a, b = float(a), float(b)
                    print(f"Setting range to {a:02f}, {b:02f}")
                    if a > b:
                        raise Exception("For consistency, with range-a,b preprocessing, b must be"
                                        " greater than a, but got {a} > {b}!")
                    # set the minimum value to 0
                    im = im - im.min()
                    # set the maximum value to 1
                    im = im / im.max()
                    # and then rescale
                    im = im * (b - a) + a
                else:
                    print("Image will *not* use full dynamic range")
                    im = im / np.iinfo(dtype).max
                if 'cone' in wildcards.img_preproc:
                    print("Raising image to the 1/3, to approximate cone response")
                    im = im ** (1/3)
                if 'gamma-corrected' in wildcards.img_preproc:
                    print("Raising image to 1/2.2, to gamma correct it")
                    im = im ** (1/2.2)
                # always save it as 16 bit
                print("Saving as 16 bit")
                im = met.utils.convert_im_to_int(im, np.uint16)
                imageio.imwrite(output[0], im)


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
        TEXTURE_DIR
    output:
        directory(TEXTURE_DIR + "_{preproc}")
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
        from skimage import color
        import foveated_metamers as met
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                os.makedirs(output[0])
                for i in glob(op.join(input[0], '*.jpg')):
                    im = imageio.imread(i)
                    im = met.utils.convert_im_to_float(im)
                    if im.ndim == 3:
                        # then it's a color image, and we need to make it grayscale
                        im = color.rgb2gray(im)
                    if 'degamma' in wildcards.preproc:
                        # 1/2.2 is the standard encoding gamma for jpegs, so we
                        # raise this to its reciprocal, 2.2, in order to reverse
                        # it
                        im = im ** 2.2
                    if 'cone' in wildcards.preproc:
                        im = im ** (1/3)
                    # save as a 16 bit png
                    im = met.utils.convert_im_to_int(im, np.uint16)
                    imageio.imwrite(op.join(output[0], op.split(i)[-1].replace('jpg', 'png')), im)


rule gen_norm_stats:
    input:
        TEXTURE_DIR + "{preproc}"
    output:
        # here V1 and texture could be considered wildcards, but they're
        # the only we're doing this for now
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture{preproc}_'
                'norm_stats-{num}.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture'
                '{preproc}_norm_stats-{num}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture'
                '{preproc}_norm_stats-{num}_benchmark.txt')
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
                                                  include_highpass=True,
                                                  cell_types=['complex', 'simple_on', 'simple_off'])
                po.optim.generate_norm_stats(v1, input[0], output[0], (512, 512),
                                             index=params.index)


# we need to generate the stats in blocks, and then want to re-combine them
rule combine_norm_stats:
    input:
        lambda wildcards: [op.join(config['DATA_DIR'], 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture'
                                   '{preproc}_norm_stats-{num}.pt').format(num=i, **wildcards)
                           for i in range(9)]
    output:
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture{preproc}_norm_stats.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture'
                '{preproc}_norm_stats.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_nl-{nonlin}_cone-{cone}_texture'
                '{preproc}_norm_stats_benchmark.txt')
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


def get_mem_estimate(wildcards):
    r"""estimate the amount of memory that this will need, in GB
    """
    try:
        if 'size-2048,2600' in wildcards.image_name:
            if 'gaussian' in wildcards.model_name:
                if 'V1' in wildcards.model_name:
                    return 16
                if 'RGC' in wildcards.model_name:
                    # this is an approximation of the size of their windows,
                    # and if you have at least 3 times this memory, you're
                    # good. double-check this value -- the 1.36 is for
                    # converting form 2048,3528 (which the numbers came
                    # from) to 2048,2600 (which has 1.36x fewer pixels)
                    window_size = 1.17430726 / (1.36*float(wildcards.scaling))
                    return int(3 * window_size)
            if 'cosine' in wildcards.model_name:
                if 'V1' in wildcards.model_name:
                    # most it will need is 32 GB
                    return 32
                if 'RGC' in wildcards.model_name:
                    # this is an approximation of the size of their windows,
                    # and if you have at least 3 times this memory, you're
                    # good
                    window_size = 0.49238059 / float(wildcards.scaling)
                    return int(3 * window_size)
        else:
            # don't have a good estimate for these
            return 16
    except AttributeError:
        # then we don't have a image_name wildcard (and thus this is
        # being called by cache_windows)
        if wildcards.size == '2048,2600':
            if wildcards.window_type == 'gaussian':
                # this is an approximation of the size of their windows,
                # and if you have at least 3 times this memory, you're
                # good. double-check this value -- the 1.36 is for
                # converting form 2048,3528 (which the numbers came
                # from) to 2048,2600 (which has 1.36x fewer pixels)
                window_size = 1.17430726 / (1.36*float(wildcards.scaling))
                return int(3 * window_size)
            elif wildcards.window_type == 'cosine':
                # this is an approximation of the size of their windows,
                # and if you have at least 3 times this memory, you're
                # good
                window_size = 0.49238059 / float(wildcards.scaling)
                return int(3 * window_size)
        else:
            # don't have a good estimate here
            return 16


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
    resources:
        mem = get_mem_estimate,
    run:
        import contextlib
        import plenoptic as po
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                img_size = [int(i) for i in wildcards.size.split(',')]
                kwargs = {}
                if wildcards.window_type == 'cosine':
                    t_width = float(wildcards.t_width)
                    std_dev = None
                    min_ecc = float(wildcards.min_ecc)
                elif wildcards.window_type == 'gaussian':
                    std_dev = float(wildcards.t_width)
                    t_width = None
                    min_ecc = float(wildcards.min_ecc)
                elif wildcards.window_type == 'dog':
                    # in this case, the t_width wildcard will be a bit
                    # more complicated, and we need to parse it more
                    t_width = wildcards.t_width.split('_')
                    std_dev = float(t_width[0])
                    if not t_width[1].startswith('s-'):
                        raise Exception("DoG windows require surround_std_dev!")
                    kwargs['surround_std_dev'] = float(t_width[1].split('-')[-1])
                    if not t_width[2].startswith('r-'):
                        raise Exception("DoG windows require center_surround_ratio!")
                    kwargs['center_surround_ratio'] = float(t_width[2].split('-')[-1])
                    t_width = None
                    min_ecc = None
                    kwargs['transition_x'] = float(wildcards.min_ecc)
                po.simul.PoolingWindows(float(wildcards.scaling), img_size, min_ecc,
                                        float(wildcards.max_ecc), cache_dir=op.dirname(output[0]),
                                        transition_region_width=t_width, std_dev=std_dev,
                                        window_type=wildcards.window_type, **kwargs)


def get_norm_dict(wildcards):
    if 'norm' in wildcards.model_name:
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
        try:
            nonlin = re.findall("_nl-([24]+)_", wildcards.model_name)[0]
        except (IndexError, ValueError):
            nonlin = 2
        return op.join(config['DATA_DIR'], 'norm_stats', 'V1_nl-%s_cone-%s_texture%s_norm_stats.pt'
                       % (nonlin, cone_power, preproc))
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
    elif 'dog' in wildcards.model_name:
        # then model_name will also include the center_surround_ratio
        # and surround_std_dev
        window_type = 'dog'
        surround_std_dev = [n for n in wildcards.model_name.split('_') if n.startswith('s-')][0]
        center_surround_ratio = [n for n in wildcards.model_name.split('_') if n.startswith('r-')][0]
        t_width = f'1.0_{surround_std_dev}_{center_surround_ratio}'
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
            windows.append(window_template.format(scaling=wildcards.scaling, size=output_size,
                                                  max_ecc=float(wildcards.max_ecc),
                                                  min_ecc=float(wildcards.min_ecc),
                                                  t_width=t_width, window_type=window_type))
        return windows


rule create_metamers:
    input:
        ref_image = lambda wildcards: utils.get_ref_image_full_path(wildcards.image_name),
        windows = get_windows,
        norm_dict = get_norm_dict,
    output:
        METAMER_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'history.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'history.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'window_check.svg'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        METAMER_TEMPLATE_PATH.replace('.png', '.npy'),
        report(METAMER_TEMPLATE_PATH),
    log:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'lt-{loss_change_thresh}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-'
                '{max_iter}_thresh-{loss_thresh}_gpu-{gpu}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'lt-{loss_change_thresh}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'seed-{seed}_init-{init_type}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-'
                '{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_benchmark.txt')
    resources:
        gpu = lambda wildcards: int(wildcards.gpu),
        mem = get_mem_estimate,
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
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
                if wildcards.coarse_to_fine == 'False':
                    coarse_to_fine = False
                else:
                    coarse_to_fine = wildcards.coarse_to_fine
                if wildcards.init_type not in ['white', 'blue', 'pink', 'gray']:
                    init_type = REF_IMAGE_TEMPLATE_PATH.format(image_name=wildcards.init_type)
                else:
                    init_type = wildcards.init_type
                if resources.gpu == 1:
                    get_gid = True
                elif resources.gpu == 0:
                    get_gid = False
                else:
                    raise Exception("Multiple gpus are not supported!")
                with met.utils.get_gpu_id(get_gid) as gpu_id:
                    met.create_metamers.main(wildcards.model_name, float(wildcards.scaling),
                                             input.ref_image, int(wildcards.seed), float(wildcards.min_ecc),
                                             float(wildcards.max_ecc), float(wildcards.learning_rate),
                                             int(wildcards.max_iter), float(wildcards.loss_thresh),
                                             output[0], init_type, gpu_id,
                                             params.cache_dir, input.norm_dict,
                                             wildcards.optimizer, float(wildcards.fract_removed),
                                             float(wildcards.loss_fract),
                                             float(wildcards.loss_change_thresh), coarse_to_fine,
                                             wildcards.clamp, clamp_each_iter, wildcards.loss)


def find_attempts(wildcards):
    wildcards = dict(wildcards)
    num = wildcards.pop('num', None)
    wildcards.pop('extra_iter', None)
    i = 0
    while len(glob(CONTINUE_TEMPLATE_PATH.format(num=i, extra_iter='*', **wildcards))) > 0:
        i += 1
    # I would like to ensure that num is i, but to make the DAG we have
    # to go backwards and check each attempt, so this function does not
    # only get called for the rule the user calls
    if num is not None and int(num) > i:
        raise Exception("attempts at continuing metamers need to use strictly increasing num")
    if i > 0:
        return glob(CONTINUE_TEMPLATE_PATH.format(num=i-1, extra_iter='*', **wildcards))[0]
    else:
        return METAMER_TEMPLATE_PATH.format(**wildcards)


rule continue_metamers:
    input:
        ref_image = lambda wildcards: utils.get_ref_image_full_path(wildcards.image_name),
        norm_dict = get_norm_dict,
        continue_path = lambda wildcards: find_attempts(wildcards).replace('_metamer.png', '.pt'),
    output:
        CONTINUE_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'history.csv'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'history.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'window_check.svg'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        CONTINUE_TEMPLATE_PATH.replace('.png', '.npy'),
        report(CONTINUE_TEMPLATE_PATH),
    log:
        op.join(config["DATA_DIR"], 'logs', 'metamers_continue', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'lt-{loss_change_thresh}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'attempt-{num}_iter-{extra_iter}', 'seed-{seed}_init-{init_type}_lr-'
                '{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'metamers_continue', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}', 'fr-{fract_removed}_lc-{loss_fract}_'
                'lt-{loss_change_thresh}_cf-{coarse_to_fine}_{clamp}-{clamp_each_iter}',
                'attempt-{num}_iter-{extra_iter}', 'seed-{seed}_init-{init_type}_lr-'
                '{learning_rate}_e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_benchmark.txt')
    resources:
        gpu = lambda wildcards: int(wildcards.gpu),
        mem = get_mem_estimate,
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
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
                if wildcards.coarse_to_fine == 'False':
                    coarse_to_fine = False
                else:
                    coarse_to_fine = wildcards.coarse_to_fine
                if wildcards.init_type not in ['white', 'blue', 'pink', 'gray']:
                    init_type = REF_IMAGE_TEMPLATE_PATH.format(image_name=wildcards.init_type)
                else:
                    init_type = wildcards.init_type
                if resources.gpu == 1:
                    get_gid = True
                elif resources.gpu == 0:
                    get_gid = False
                else:
                    raise Exception("Multiple gpus are not supported!")
                with met.utils.get_gpu_id(get_gid) as gpu_id:
                    # this is the same as the original call in the
                    # create_metamers rule, except we replace max_iter with
                    # extra_iter, set learning_rate to None, and add the
                    # input continue_path at the end
                    met.create_metamers.main(wildcards.model_name, float(wildcards.scaling),
                                             input.ref_image, int(wildcards.seed), float(wildcards.min_ecc),
                                             float(wildcards.max_ecc), None,
                                             int(wildcards.extra_iter), float(wildcards.loss_thresh),
                                             output[0], init_type, gpu_id,
                                             params.cache_dir, input.norm_dict,
                                             wildcards.optimizer, float(wildcards.fract_removed),
                                             float(wildcards.loss_fract),
                                             float(wildcards.loss_change_thresh), coarse_to_fine,
                                             wildcards.clamp, clamp_each_iter, wildcards.loss,
                                             input.continue_path)


rule postproc_metamers:
    input:
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'summary.csv'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'history.csv'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'history.png'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'synthesis.mp4'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'window_check.svg'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'rep.png'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'windowed.png'),
        lambda wildcards: find_attempts(wildcards).replace('metamer.png', 'metamer-16.png'),
        lambda wildcards: find_attempts(wildcards),
        float32_array = lambda wildcards: find_attempts(wildcards).replace('.png', '.npy'),
    output:
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'history.csv'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'history.png'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'window_check.svg'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        OUTPUT_TEMPLATE_PATH,
        OUTPUT_TEMPLATE_PATH.replace('.png', '.npy'),
        report(OUTPUT_TEMPLATE_PATH.replace('metamer.png', 'metamer_gamma-corrected.png')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'postproc_metamers', '{model_name}',
                '{image_name}', 'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}',
                'fr-{fract_removed}_lc-{loss_fract}_lt-{loss_change_thresh}_cf-{coarse_to_fine}_'
                '{clamp}-{clamp_each_iter}',  'seed-{seed}_init-{init_type}_lr-{learning_rate}_'
                'e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'postproc_metamers', '{model_name}',
                '{image_name}', 'scaling-{scaling}', 'opt-{optimizer}_loss-{loss}',
                'fr-{fract_removed}_lc-{loss_fract}_lt-{loss_change_thresh}_cf-{coarse_to_fine}_'
                '{clamp}-{clamp_each_iter}', 'seed-{seed}_init-{init_type}_lr-{learning_rate}_'
                'e0-{min_ecc}_em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_gpu-{gpu}_benchmark.txt')
    run:
        import foveated_metamers as met
        import contextlib
        import numpy as np
        import shutil
        import foveated_metamers as met
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                for i, f in enumerate(output):
                    if ('cone' in wildcards.image_name and
                        (f.endswith('metamer.png') or f.endswith('metamer-16.png'))):
                        print("De-conifying image %s, saving at %s" % (input.float32_array, f))
                        im = np.load(input.float32_array)
                        dtype = {False: np.uint8, True: np.uint16}['16' in f]
                        print("Saving as image dtype %s" % dtype)
                        im = im ** 3
                        im = met.utils.convert_im_to_int(im, dtype)
                        imageio.imwrite(f, im)
                    elif f.endswith('metamer_gamma-corrected.png'):
                        if ('degamma' in wildcards.image_name or
                            any([i in wildcards.image_name for i in LINEAR_IMAGES])):
                            print("Saving gamma-corrected image %s" % f)
                            im = np.load(input.float32_array)
                            dtype = np.uint8
                            print("Retaining image dtype %s" % dtype)
                            # need to first de-cone the image, then
                            # gamma-correct it
                            if 'cone' in wildcards.image_name:
                                im = im ** 3
                            im = im ** (1/2.2)
                            im = met.utils.convert_im_to_int(im, dtype)
                            imageio.imwrite(f, im)
                        else:
                            print("Image already gamma-corrected, copying to %s" % f)
                            shutil.copy(f.replace('_gamma-corrected', ''), f)
                    else:
                        print("Copy file %s to %s" % (input[i], f))
                        shutil.copy(input[i], f)


rule collect_metamers_example:
    # this is for a shorter version of the experiment, the goal is to
    # create a test version for teaching someone how to run the
    # experiment or for demos
    input:
        utils.generate_metamer_paths('RGC', seed=2,
                                     image_name=config['DEFAULT_METAMERS']['image_name'][0]),
        utils.get_ref_image_full_path(IMAGES[2].replace('cone_', '')),
    output:
        op.join(config["DATA_DIR"], 'stimuli', 'RGC_cone-1.0_norm_gaussian_demo', 'stimuli.npy'),
        report(op.join(config["DATA_DIR"], 'stimuli', 'RGC_cone-1.0_norm_gaussian_demo', 'stimuli_description.csv')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'RGC_demo', 'stimuli.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'RGC_demo', 'stimuli_benchmark.txt'),
    run:
        import foveated_metamers as met
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                met.stimuli.collect_images(input, output[0])
                met.stimuli.create_metamer_df(input, output[1])


rule collect_metamers:
    input:
        lambda wildcards: [m.replace('metamer.png', 'metamer-16.png') for m in
                           utils.generate_metamer_paths(**wildcards)],
        # we don't want the "cone_full" images, we want the "full"
        # images.
        lambda wildcards: [utils.get_ref_image_full_path(i.replace('cone_', '')) for i in IMAGES]
    output:
        # we collect across image_name and scaling, and don't care about
        # learning_rate, max_iter, loss_thresh
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli.npy'),
        report(op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description.csv')),
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
        report(op.join(config["DATA_DIR"], 'stimuli', '{model_name}', '{subject}_idx_sess-{num}.npy')),
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
                 '{num}.npy').format(model_name=m, subject=s, num=n)
         for s in config['PSYCHOPHYSICS']['SUBJECTS']
         for n in config['PSYCHOPHYSICS']['SESSIONS'] for m in MODELS],


rule scaling_comparison_figure:
    input:
        lambda wildcards: [m.replace('metamer.png', 'metamer_gamma-corrected.png') for m in
                           utils.generate_metamer_paths(**wildcards)],
        lambda wildcards: utils.get_ref_image_full_path(utils.get_gamma_corrected_ref_image(wildcards.image_name))
    output:
        report(op.join(config['DATA_DIR'], 'figures', '{context}', '{model_name}',
                       '{image_name}_seed-{seed}_scaling.svg'))
    log:
        op.join(config['DATA_DIR'], 'logs', 'figures', '{context}', '{model_name}',
                '{image_name}_seed-{seed}_scaling.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'figures', '{context}', '{model_name}',
                '{image_name}_seed-{seed}_scaling_benchmark.txt')
    run:
        import foveated_metamers as met
        import seaborn as sns
        import contextlib
        import re
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                font_scale = {'poster': 1.7}.get(wildcards.context, 1)
                template_path = input[0].replace(wildcards.image_name, '{image_name}')
                for key in ['seed', 'scaling']:
                    template_path = re.sub(f'{key}-[0-9.]+', f'{key}-{{{key}}}', template_path)
                max_ecc = int(re.findall('em-([0-9]+)', template_path)[0])
                ref_path = input[-1].replace(wildcards.image_name.replace('cone_', 'gamma-corrected_'),
                                             '{image_name}')
                with sns.plotting_context(wildcards.context, font_scale=font_scale):
                    scaling = {MODELS[0]: RGC_SCALING, MODELS[1]: V1_SCALING}[wildcards.model_name]
                    fig = met.figures.scaling_comparison_figure(
                        wildcards.image_name, scaling, wildcards.seed, max_ecc=max_ecc,
                        ref_template_path=ref_path, metamer_template_path=template_path)
                    fig.savefig(output[0], bbox_inches='tight')
