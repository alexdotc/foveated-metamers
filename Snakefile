import os
import re
import imageio
import time
import os.path as op
import numpy as np
from plenoptic.simulate import pooling
from foveated_metamers import utils

configfile:
    "config.yml"
if not op.isdir(config["DATA_DIR"]):
    raise Exception("Cannot find the dataset at %s" % config["DATA_DIR"])
if os.system("module list") == 0:
    # then we're on the cluster
    ON_CLUSTER = True
else:
    ON_CLUSTER = False
wildcard_constraints:
    num="[0-9]+",
    pad_mode="constant|symmetric",
    period="[0-9]+",
    size="[0-9,]+",
    bits="[0-9]+",
    img_preproc="full|degamma|gamma-corrected|gamma-corrected_full|range-[,.0-9]+|gamma-corrected_range-[,.0-9]+",
    preproc_image_name="|".join([im+'_?[a-z]*' for im in config['IMAGE_NAME']['ref_image']]),
    preproc="|_degamma|degamma",
    gpu="0|1",
    sess_num="|".join([f'{i:02d}' for i in range(3)]),
    im_num="|".join([f'{i:02d}' for i in range(4)]),
    task='abx|split',
    comp='met|ref',
    save_all='|_saveall',
ruleorder:
    collect_training_metamers > collect_training_noise > collect_metamers > demosaic_image > preproc_image > crop_image > generate_image > degamma_image

LINEAR_IMAGES = config['IMAGE_NAME']['ref_image']
MODELS = [config[i]['model_name'] for i in ['RGC', 'V1']]
IMAGES = config['DEFAULT_METAMERS']['image_name']
# this is ugly, but it's easiest way to just replace the one format
# target while leaving the others alone
DATA_DIR = config['DATA_DIR']
if not DATA_DIR.endswith('/'):
    DATA_DIR += '/'
REF_IMAGE_TEMPLATE_PATH = config['REF_IMAGE_TEMPLATE_PATH'].replace("{DATA_DIR}/", DATA_DIR)
# the regex here removes all string formatting codes from the string,
# since Snakemake doesn't like them
METAMER_TEMPLATE_PATH = re.sub(":.*?}", "}", config['METAMER_TEMPLATE_PATH'].replace("{DATA_DIR}/", DATA_DIR))
METAMER_LOG_PATH = METAMER_TEMPLATE_PATH.replace('metamers/{model_name}', 'logs/metamers/{model_name}').replace('_metamer.png', '.log')
CONTINUE_TEMPLATE_PATH = (METAMER_TEMPLATE_PATH.replace('metamers/{model_name}', 'metamers_continue/{model_name}')
                          .replace("{clamp_each_iter}/", "{clamp_each_iter}/attempt-{num}_iter-{extra_iter}"))
CONTINUE_LOG_PATH = CONTINUE_TEMPLATE_PATH.replace('metamers_continue/{model_name}', 'logs/metamers_continue/{model_name}').replace('_metamer.png', '.log')
TEXTURE_DIR = config['TEXTURE_DIR']
if TEXTURE_DIR.endswith(os.sep) or TEXTURE_DIR.endswith('/'):
    TEXTURE_DIR = TEXTURE_DIR[:-1]


# quick rule to check that there are GPUs available and the environment
# has been set up correctly.
rule test_setup:
    input:
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[0],
                                     image_name='einstein_degamma_size-256,256',
                                     scaling=.1, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     coarse_to_fine=False, seed=0, init_type='white',
                                     learning_rate=1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=0,
                                     clamp='clamp', clamp_each_iter=True, loss='l2',
                                     loss_change_thresh=.1, loss_change_iter=50,
                                     save_all=''),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[1],
                                     image_name='einstein_degamma_size-256,256',
                                     scaling=.5, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     loss_change_thresh=0.01, seed=0, init_type='white',
                                     learning_rate=.1, min_ecc=.5, max_ecc=15, max_iter=100,
                                     loss_thresh=1e-8, gpu=0, coarse_to_fine='together',
                                     clamp='clamp', clamp_each_iter=True, loss='l2',
                                     loss_change_iter=50, save_all=''),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[0],
                                     image_name='einstein_degamma_size-256,256',
                                     scaling=.1, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     coarse_to_fine=False, seed=0, init_type='white',
                                     learning_rate=1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=1,
                                     clamp='clamp', clamp_each_iter=True, loss='l2',
                                     loss_change_thresh=.1, loss_change_iter=50, save_all=''),
        METAMER_TEMPLATE_PATH.format(model_name=MODELS[1],
                                     image_name='einstein_degamma_size-256,256',
                                     scaling=.5, optimizer='Adam', fract_removed=0, loss_fract=1,
                                     loss_change_thresh=0.01, seed=0, init_type='white',
                                     learning_rate=.1, min_ecc=.5, max_ecc=15,
                                     max_iter=100, loss_thresh=1e-8, gpu=1, clamp='clamp',
                                     clamp_each_iter=True, loss='l2', coarse_to_fine='together',
                                     loss_change_iter=50, save_all=''),
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
        [utils.get_ref_image_full_path(utils.get_gamma_corrected_ref_image(i))
         for i in IMAGES],
        [utils.get_ref_image_full_path(i) for i in IMAGES],


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
        import foveated_metamers as fov
        from skimage import color
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0])
                # when loaded in, the range of this will be 0 to 255, we
                # want to convert it to 0 to 1
                im = fov.utils.convert_im_to_float(im)
                # convert to grayscale
                im = color.rgb2gray(im)
                # 1/2.2 is the standard encoding gamma for jpegs, so we
                # raise this to its reciprocal, 2.2, in order to reverse
                # it
                im = im**2.2
                dtype = eval('np.uint%s' % wildcards.bits)
                imageio.imwrite(output[0], fov.utils.convert_im_to_int(im, dtype))


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
        import foveated_metamers as fov
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                im = imageio.imread(input[0])
                curr_shape = np.array(im.shape)[:2]
                target_shape = [int(i) for i in wildcards.size.split(',')]
                print(curr_shape, target_shape)
                if len(target_shape) == 1:
                    target_shape = 2* target_shape
                target_shape = np.array(target_shape)
                crop_amt = curr_shape - target_shape
                # this is ugly, but I can't come up with an easier way to make
                # sure that we skip a dimension if crop_amt is 0 for it
                cropped_im = im
                for i, c in enumerate(crop_amt):
                    if c == 0:
                        continue
                    else:
                        if i == 0:
                            cropped_im = cropped_im[c//2:-c//2]
                        elif i == 1:
                            cropped_im = cropped_im[:, c//2:-c//2]
                        else:
                            raise Exception("Can only crop up to two dimensions!")
                cropped_im = color.rgb2gray(cropped_im)
                imageio.imwrite(output[0], fov.utils.convert_im_to_int(cropped_im, np.uint16))
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
        import foveated_metamers as fov
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
                if 'gamma-corrected' in wildcards.img_preproc:
                    print("Raising image to 1/2.2, to gamma correct it")
                    im = im ** (1/2.2)
                # always save it as 16 bit
                print("Saving as 16 bit")
                im = fov.utils.convert_im_to_int(im, np.uint16)
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
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.stimuli.pad_image(input[0], wildcards.pad_mode, output[0])


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
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.stimuli.create_image(wildcards.image_type, int(wildcards.size), output[0],
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
        import foveated_metamers as fov
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                os.makedirs(output[0])
                for i in glob(op.join(input[0], '*.jpg')):
                    im = imageio.imread(i)
                    im = fov.utils.convert_im_to_float(im)
                    if im.ndim == 3:
                        # then it's a color image, and we need to make it grayscale
                        im = color.rgb2gray(im)
                    if 'degamma' in wildcards.preproc:
                        # 1/2.2 is the standard encoding gamma for jpegs, so we
                        # raise this to its reciprocal, 2.2, in order to reverse
                        # it
                        im = im ** 2.2
                    # save as a 16 bit png
                    im = fov.utils.convert_im_to_int(im, np.uint16)
                    imageio.imwrite(op.join(output[0], op.split(i)[-1].replace('jpg', 'png')), im)


rule gen_norm_stats:
    input:
        TEXTURE_DIR + "{preproc}"
    output:
        # here V1 and texture could be considered wildcards, but they're
        # the only we're doing this for now
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_texture{preproc}_'
                'norm_stats-{num}.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_texture'
                '{preproc}_norm_stats-{num}.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_texture'
                '{preproc}_norm_stats-{num}_benchmark.txt')
    params:
        index = lambda wildcards: (int(wildcards.num) * 100, (int(wildcards.num)+1) * 100)
    run:
        import plenoptic as po
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                # scaling doesn't matter here
                v1 = po.simul.PooledV1(1, (512, 512), num_scales=6)
                po.optim.generate_norm_stats(v1, input[0], output[0], (512, 512),
                                             index=params.index)


# we need to generate the stats in blocks, and then want to re-combine them
rule combine_norm_stats:
    input:
        lambda wildcards: [op.join(config['DATA_DIR'], 'norm_stats', 'V1_texture'
                                   '{preproc}_norm_stats-{num}.pt').format(num=i, **wildcards)
                           for i in range(9)]
    output:
        op.join(config['DATA_DIR'], 'norm_stats', 'V1_texture{preproc}_norm_stats.pt' )
    log:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_texture'
                '{preproc}_norm_stats.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'norm_stats', 'V1_texture'
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


def get_mem_estimate(wildcards, partition=None):
    r"""estimate the amount of memory that this will need, in GB
    """
    try:
        if 'size-2048,2600' in wildcards.image_name:
            if 'gaussian' in wildcards.model_name:
                if 'V1' in wildcards.model_name:
                    if float(wildcards.scaling) < .01:
                        mem = 128
                    else:
                        mem = 64
                if 'RGC' in wildcards.model_name:
                    # this is an approximation of the size of their windows,
                    # and if you have at least 3 times this memory, you're
                    # good. double-check this value -- the 1.36 is for
                    # converting form 2048,3528 (which the numbers came
                    # from) to 2048,2600 (which has 1.36x fewer pixels)
                    window_size = 1.17430726 / (1.36*float(wildcards.scaling))
                    mem = int(5 * window_size)
            if 'cosine' in wildcards.model_name:
                if 'V1' in wildcards.model_name:
                    # most it will need is 32 GB
                    mem = 32
                if 'RGC' in wildcards.model_name:
                    # this is an approximation of the size of their windows,
                    # and if you have at least 3 times this memory, you're
                    # good
                    window_size = 0.49238059 / float(wildcards.scaling)
                    mem = int(5 * window_size)
        else:
            # don't have a good estimate for these
            mem = 16
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
                mem = int(5 * window_size)
            elif wildcards.window_type == 'cosine':
                # this is an approximation of the size of their windows,
                # and if you have at least 3 times this memory, you're
                # good
                window_size = 0.49238059 / float(wildcards.scaling)
                mem = int(5 * window_size)
        else:
            # don't have a good estimate here
            mem = 16
    try:
        if wildcards.save_all:
            # for this estimate, RGC with scaling .095 went from 36GB requested
            # to about 54GB used when stored iterations went from 100 to 1000.
            # that's 1.5x higher, and we add a bit of a buffer. also, don't
            # want to reduce memory estimate
            mem_factor = max((int(wildcards.max_iter) / 100) * (1.7/10), 1)
            mem *= mem_factor
    except AttributeError:
        # then we're missing either the save_all or max_iter wildcard, in which
        # case this is probably cache_windows and the above doesn't matter
        pass
    mem = int(np.ceil(mem))
    if partition == 'rusty':
        if int(wildcards.gpu) == 0:
            # in this case, we *do not* want to specify memory (we'll get the
            # whole node allocated but slurm could still kill the job if we go
            # over requested memory)
            mem = ''
        else:
            # we'll be plugging this right into the mem request to slurm, so it
            # needs to be exactly correct
            mem = f"{mem}GB"
    return mem


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
        return op.join(config['DATA_DIR'], 'norm_stats', f'V1_texture{preproc}'
                       '_norm_stats.pt')
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
            windows.append(window_template.format(scaling=wildcards.scaling, size=output_size,
                                                  max_ecc=float(wildcards.max_ecc),
                                                  min_ecc=float(wildcards.min_ecc),
                                                  t_width=t_width, window_type=window_type))
        return windows

def get_partition(wildcards, cluster):
    # if our V1 scaling value is small enough, we need a V100 and must specify
    # it. otherwise, we can use any GPU, because they'll all have enough
    # memory. The partition name depends on the cluster (prince or rusty), so
    # we have two different params, one for each, and the cluster config grabs
    # the right one
    if cluster not in ['prince', 'rusty']:
        raise Exception(f"Don't know how to handle cluster {cluster}")
    if int(wildcards.gpu) == 0:
        if cluster == 'rusty':
            return 'ccn'
        elif cluster == 'prince':
            return None
    else:
        scaling = float(wildcards.scaling)
        if cluster == 'rusty':
            return 'gpu'
        elif cluster == 'prince':
            part = 'simoncelli_gpu,v100_sxm2_4,v100_pci_2'
            if scaling >= .18:
                part += ',p40_4'
            if scaling >= .4:
                part += ',p100_4'
            return part

def get_constraint(wildcards, cluster):
    if int(wildcards.gpu) > 0 and cluster == 'rusty':
        return 'v100-32gb'
    else:
        return ''

def get_cpu_num(wildcards):
    if int(wildcards.gpu) > 0:
        # then we're using the GPU and so don't really need CPUs
        cpus = 1
    else:
        # these are all based on estimates from rusty (which automatically
        # gives each job 28 nodes), and checking seff to see CPU usage
        if float(wildcards.scaling) > .06:
            cpus = 21
        elif float(wildcards.scaling) > .03:
            cpus = 26
        else:
            cpus = 28
    return cpus


def get_init_image(wildcards):
    if wildcards.init_type in ['white', 'gray', 'pink', 'blue']:
        return []
    else:
        return utils.get_ref_image_full_path(wildcards.init_type)

rule create_metamers:
    input:
        ref_image = lambda wildcards: utils.get_ref_image_full_path(wildcards.image_name),
        windows = get_windows,
        norm_dict = get_norm_dict,
        init_image = get_init_image,
    output:
        METAMER_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'history.csv'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'history.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'window_check.svg'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        METAMER_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        METAMER_TEMPLATE_PATH.replace('.png', '.npy'),
        report(METAMER_TEMPLATE_PATH),
    log:
        METAMER_LOG_PATH,
    benchmark:
        METAMER_LOG_PATH.replace('.log', '_benchmark.txt'),
    resources:
        gpu = lambda wildcards: int(wildcards.gpu),
        cpus_per_task = get_cpu_num,
        mem = get_mem_estimate,
        # this seems to be the best, anymore doesn't help and will eventually hurt
        num_threads = 12,
    params:
        rusty_mem = lambda wildcards: get_mem_estimate(wildcards, 'rusty'),
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
        time = lambda wildcards: {'V1': '12:00:00', 'RGC': '7-00:00:00'}[wildcards.model_name.split('_')[0]],
        rusty_partition = lambda wildcards: get_partition(wildcards, 'rusty'),
        prince_partition = lambda wildcards: get_partition(wildcards, 'prince'),
        rusty_constraint = lambda wildcards: get_constraint(wildcards, 'rusty'),
    run:
        import foveated_metamers as fov
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
                    init_type = fov.utils.get_ref_image_full_path(wildcards.init_type)
                else:
                    init_type = wildcards.init_type
                if resources.gpu == 1:
                    get_gid = True
                elif resources.gpu == 0:
                    get_gid = False
                else:
                    raise Exception("Multiple gpus are not supported!")
                if wildcards.save_all:
                    save_all = True
                else:
                    save_all = False
                with fov.utils.get_gpu_id(get_gid, on_cluster=ON_CLUSTER) as gpu_id:
                    fov.create_metamers.main(wildcards.model_name, float(wildcards.scaling),
                                             input.ref_image, int(wildcards.seed), float(wildcards.min_ecc),
                                             float(wildcards.max_ecc), float(wildcards.learning_rate),
                                             int(wildcards.max_iter), float(wildcards.loss_thresh),
                                             int(wildcards.loss_change_iter), output[0],
                                             init_type, gpu_id, params.cache_dir, input.norm_dict,
                                             wildcards.optimizer, float(wildcards.fract_removed),
                                             float(wildcards.loss_fract),
                                             float(wildcards.loss_change_thresh), coarse_to_fine,
                                             wildcards.clamp, clamp_each_iter, wildcards.loss,
                                             save_all=save_all, num_threads=resources.num_threads)


rule continue_metamers:
    input:
        ref_image = lambda wildcards: utils.get_ref_image_full_path(wildcards.image_name),
        norm_dict = get_norm_dict,
        continue_path = lambda wildcards: utils.find_attempts(dict(wildcards)).replace('_metamer.png', '.pt'),
        init_image = get_init_image,
    output:
        CONTINUE_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'summary.csv'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'history.csv'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'history.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'synthesis.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'window_check.svg'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'rep.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'windowed.png'),
        CONTINUE_TEMPLATE_PATH.replace('metamer.png', 'metamer-16.png'),
        CONTINUE_TEMPLATE_PATH.replace('.png', '.npy'),
        report(CONTINUE_TEMPLATE_PATH),
    log:
        CONTINUE_LOG_PATH,
    benchmark:
        CONTINUE_LOG_PATH.replace('.log', '_benchmark.txt'),
    resources:
        gpu = lambda wildcards: int(wildcards.gpu),
        mem = get_mem_estimate,
        cpus_per_task = get_cpu_num,
        # this seems to be the best, anymore doesn't help and will eventually hurt
        num_threads = 12,
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
        time = lambda wildcards: {'V1': '12:00:00', 'RGC': '7-00:00:00'}[wildcards.model_name.split('_')[0]],
        rusty_partition = lambda wildcards: get_partition(wildcards, 'rusty'),
        prince_partition = lambda wildcards: get_partition(wildcards, 'prince'),
        rusty_constraint = lambda wildcards: get_constraint(wildcards, 'rusty'),
    run:
        import foveated_metamers as fov
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
                    init_type = fov.utils.get_ref_image_full_path(wildcards.init_type)
                else:
                    init_type = wildcards.init_type
                if resources.gpu == 1:
                    get_gid = True
                elif resources.gpu == 0:
                    get_gid = False
                else:
                    raise Exception("Multiple gpus are not supported!")
                with fov.utils.get_gpu_id(get_gid) as gpu_id:
                    # this is the same as the original call in the
                    # create_metamers rule, except we replace max_iter with
                    # extra_iter, set learning_rate to None, and add the
                    # input continue_path at the end
                    fov.create_metamers.main(wildcards.model_name, float(wildcards.scaling),
                                             input.ref_image, int(wildcards.seed), float(wildcards.min_ecc),
                                             float(wildcards.max_ecc), None,
                                             int(wildcards.extra_iter), float(wildcards.loss_thresh),
                                             int(wildcards.loss_change_iter), output[0],
                                             init_type, gpu_id, params.cache_dir, input.norm_dict,
                                             wildcards.optimizer, float(wildcards.fract_removed),
                                             float(wildcards.loss_fract),
                                             float(wildcards.loss_change_thresh), coarse_to_fine,
                                             wildcards.clamp, clamp_each_iter, wildcards.loss,
                                             input.continue_path, num_threads=resources.num_threads)


rule gamma_correct_metamer:
    input:
        lambda wildcards: [m.replace('metamer.png', 'metamer.npy') for m in
                           utils.generate_metamer_paths(**wildcards)]
    output:
        report(METAMER_TEMPLATE_PATH.replace('metamer.png', 'metamer_gamma-corrected.png'))
    log:
        METAMER_LOG_PATH.replace('.log', '_gamma-corrected.log')
    benchmark:
        METAMER_LOG_PATH.replace('.log', '_gamma-corrected_benchmark.txt')
    run:
        import foveated_metamers as fov
        import contextlib
        import numpy as np
        import shutil
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                if output[0].endswith('metamer_gamma-corrected.png'):
                    if ('degamma' in wildcards.image_name or
                        any([i in wildcards.image_name for i in LINEAR_IMAGES])):
                        print(f"Saving gamma-corrected image {output[0]} as np.uint8")
                        im = np.load(input[0])
                        im = im ** (1/2.2)
                        im = fov.utils.convert_im_to_int(im, np.uint8)
                        imageio.imwrite(output[0], im)
                    else:
                        print("Image already gamma-corrected, copying to {output[0]}")
                        shutil.copy(output[0].replace('_gamma-corrected', ''), output[0])


# for subject to learn task structure: comparing noise and reference images
rule collect_training_noise:
    input:
        # this duplication is *on purpose*. it's the easiest way of making sure
        # each of them show up twice in our stimuli array and description
        # dataframe
        op.join(config['DATA_DIR'], 'ref_images', 'uniform-noise_size-2048,2600.png'),
        op.join(config['DATA_DIR'], 'ref_images', 'pink-noise_size-2048,2600.png'),
        op.join(config['DATA_DIR'], 'ref_images', 'uniform-noise_size-2048,2600.png'),
        op.join(config['DATA_DIR'], 'ref_images', 'pink-noise_size-2048,2600.png'),
        [utils.get_ref_image_full_path(i) for i in IMAGES[:2]],
    output:
        op.join(config["DATA_DIR"], 'stimuli', 'training_noise', 'stimuli_comp-{comp}.npy'),
        report(op.join(config["DATA_DIR"], 'stimuli', 'training_noise', 'stimuli_description_comp-{comp}.csv')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'training_noise', 'stimuli_comp-{comp}.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'training_noise', 'stimuli_comp-{comp}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import contextlib
        import pandas as pd
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.stimuli.collect_images(input[:6], output[0])
                df = []
                for i, p in enumerate(input):
                    if i < 4:
                        image_name = op.basename(input[-2:][i//2]).replace('.pgm', '').replace('.png', '')
                        # dummy scaling value
                        scaling = 1
                        model = 'training'
                        seed = i % 2
                    else:
                        image_name = op.basename(p).replace('.pgm', '').replace('.png', '')
                        scaling = None
                        model = None
                        seed = None
                    df.append(pd.DataFrame({'base_signal': p, 'image_name': image_name, 'model': model,
                                            'scaling': scaling, 'seed': seed}, index=[0]))
                pd.concat(df).to_csv(output[1], index=False)


def get_training_metamers(wildcards):
    scaling = [config[wildcards.model_name.split('_')[0]]['scaling'][0],
               config[wildcards.model_name.split('_')[0]]['scaling'][-1]]
    mets = utils.generate_metamer_paths(scaling=scaling, image_name=IMAGES[:2],
                                        seed_n=[0], **wildcards)
    return [m.replace('metamer.png', 'metamer.npy') for m in mets]
                    

# for subjects to get a sense for how this is done with metamers
rule collect_training_metamers:
    input:
        get_training_metamers,
        lambda wildcards: [utils.get_ref_image_full_path(i) for i in IMAGES[:2]]
    output:
        op.join(config["DATA_DIR"], 'stimuli', 'training_{model_name}', 'stimuli_comp-{comp}.npy'),
        report(op.join(config["DATA_DIR"], 'stimuli', 'training_{model_name}', 'stimuli_description_comp-{comp}.csv')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'training_{model_name}', 'stimuli_comp-{comp}.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', 'training_{model_name}', 'stimuli_comp-{comp}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.stimuli.collect_images(input, output[0])
                fov.stimuli.create_metamer_df(input, output[1])


rule collect_metamers:
    input:
        lambda wildcards: [m.replace('metamer.png', 'metamer.npy') for m in
                           utils.generate_metamer_paths(**wildcards)],
        lambda wildcards: [utils.get_ref_image_full_path(i) for i in IMAGES]
    output:
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_comp-{comp}.npy'),
        report(op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description_comp-{comp}.csv')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'stimuli_comp-{comp}.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'stimuli_comp-{comp}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.stimuli.collect_images(input, output[0])
                fov.stimuli.create_metamer_df(input, output[1])


def get_experiment_seed(wildcards):
    # the number from subject will be a number from 1 to 30, which we multiply
    # by 10 in order to get the tens/hundreds place, and the session number
    # will be between 0 and 2, which we use for the ones place. we use the same
    # seed for different model stimuli, since those will be completely
    # different sets of images.
    try:
        seed = 10*int(wildcards.subject.replace('sub-', '')) + int(wildcards.sess_num)
    except ValueError:
        # then this is the training subject and seed doesn't really matter
        seed = int(wildcards.sess_num)
    return seed


rule generate_experiment_idx:
    input:
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description_comp-{comp}.csv'),
    output:
        report(op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                       '{subject}_task-{task}_comp-{comp}_idx_sess-{sess_num}_im-{im_num}.npy')),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{subject}_task-{task}_comp-{comp}_idx_sess-{sess_num}_im-{im_num}.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{subject}_task-{task}_comp-{comp}_idx_sess-{sess_num}_im-{im_num}_benchmark.txt'),
    params:
        seed = get_experiment_seed,
    run:
        import foveated_metamers as fov
        import pandas as pd
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                stim_df = pd.read_csv(input[0])
                try:
                    # want to pick 4 of the 8 reference images per run
                    np.random.seed(int(wildcards.subject.replace('sub-', '')))
                    ref_image_idx = np.random.permutation(np.arange(8))[4*int(wildcards.im_num):4*(int(wildcards.im_num)+1)]
                except ValueError:
                    # then this is the test subject
                    if 'training' not in wildcards.model_name:
                        ref_image_idx = [0]
                        scaling_val = config[wildcards.model_name.split('_')[0]]['scaling'][-1]
                        stim_df = stim_df.fillna('None').query("scaling in [@scaling_val, 'None']")
                    else:
                        # if it is the traning model, then the stimuli description
                        # has already been restricted to only the values we want
                        ref_image_idx = [0, 1]
                ref_image_to_include = stim_df.image_name.unique()[ref_image_idx]
                stim_df = stim_df.query("image_name in @ref_image_to_include")
                comp = 'met_v_' + wildcards.comp
                if wildcards.task == 'abx':
                    idx = fov.stimuli.generate_indices_abx(stim_df, params.seed, comp)
                elif wildcards.task == 'split':
                    idx = fov.stimuli.generate_indices_split(stim_df, params.seed, comp)
                np.save(output[0], idx)


rule create_experiment_df:
    input:
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'stimuli_description_comp-{comp}.csv'),
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{subject}_task-{task}_comp-{comp}_idx_sess-{sess_num}_im-{im_num}.npy'),
        op.join(config["DATA_DIR"], 'raw_behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}.hdf5'),
    output:
        op.join(config["DATA_DIR"], 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_expt.csv'),
        op.join(config["DATA_DIR"], 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_trials.png'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'behavioral', '{model_name}', 'task-{task}_comp-{comp}',
                '{subject}', '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}_expt{kwargs}.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'behavioral', '{model_name}', 'task-{task}_comp-{comp}',
                '{subject}', '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}_expt{kwargs}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import numpy as np
        import pandas as pd
        import re
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                stim_df = pd.read_csv(input[0])
                idx = np.load(input[1])
                trials = fov.analysis.summarize_trials(input[2], wildcards.task)
                fig = fov.analysis.plot_timing_info(trials, wildcards.subject, wildcards.task,
                                                    wildcards.sess_num, wildcards.im_num)
                fig.savefig(output[1], bbox_inches='tight')
                if wildcards.task == 'abx':
                    df = fov.analysis.create_experiment_df_abx(stim_df, idx)
                elif wildcards.task == 'split':
                    df = fov.analysis.create_experiment_df_split(stim_df, idx)
                df = fov.analysis.add_response_info(df, trials, wildcards.subject, wildcards.task,
                                                    wildcards.sess_num, wildcards.im_num)
                # this will always start with a _. we want to get rid of that
                # and add one at the end, given our regex
                kwargs = wildcards.kwargs + '_'
                if kwargs[0] == '_':
                    kwargs = kwargs[1:]
                kwargs = dict(re.findall('(.*?)-(.*?)_', kwargs))
                df = df.assign(**kwargs)
                df.to_csv(output[0], index=False)


rule summarize_experiment:
    input:
        op.join(config["DATA_DIR"], 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                       '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_expt.csv'),
    output:
        op.join(config["DATA_DIR"], 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                       '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_summary.csv'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                       '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_summary.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'behavioral', '{model_name}', 'task-{task}_comp-{comp}', '{subject}',
                       '{date}_{subject}_task-{task}_comp-{comp}_sess-{sess_num}_im-{im_num}{kwargs}_summary_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import pandas as pd
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                expt_df = pd.read_csv(input[0])
                dep_variables = ['scaling', 'trial_type']
                # this will always start with a _. we want to get rid of that
                # and add one at the end, given our regex
                kwargs = wildcards.kwargs + '_'
                if kwargs[0] == '_':
                    kwargs = kwargs[1:]
                kwargs = dict(re.findall('(.*?)-(.*?)_', kwargs))
                dep_variables += list(kwargs.keys())
                summary_df = fov.analysis.summarize_expt(expt_df, dep_variables)
                summary_df.to_csv(output[0], index=False)


rule simulate_optimization:
    output:
        op.join(config['DATA_DIR'], 'simulate', 'optimization', 'a0-{a0}_s0-{s0}_seeds-{n_seeds}_iter-{max_iter}.svg'),
        op.join(config['DATA_DIR'], 'simulate', 'optimization', 'a0-{a0}_s0-{s0}_seeds-{n_seeds}_iter-{max_iter}_params.csv'),
        op.join(config['DATA_DIR'], 'simulate', 'optimization', 'a0-{a0}_s0-{s0}_seeds-{n_seeds}_iter-{max_iter}_data.csv'),
    log:
        op.join(config['DATA_DIR'], 'logs', 'simulate', 'optimization', 'a0-{a0}_s0-{s0}_seeds-{n_seeds}_iter-{max_iter}.log'),
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'simulate', 'optimization', 'a0-{a0}_s0-{s0}_seeds-{n_seeds}_iter-{max_iter}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fig, param, data = fov.simulate.test_optimization(float(wildcards.a0),
                                                                  float(wildcards.s0),
                                                                  n_opt=int(wildcards.n_seeds),
                                                                  max_iter=int(wildcards.max_iter))
                fig.savefig(output[0], bbox_inches='tight')
                param.to_csv(output[1], index=False)
                data.to_csv(output[2], index=False)


rule simulate_num_trials:
    output:
        op.join(config['DATA_DIR'], 'simulate', 'num_trials', 'trials-{n_trials}_a0-{a0}_s0-{s0}_boots-{n_boots}_iter-{max_iter}.svg'),
        op.join(config['DATA_DIR'], 'simulate', 'num_trials', 'trials-{n_trials}_a0-{a0}_s0-{s0}_boots-{n_boots}_iter-{max_iter}_params.csv'),
        op.join(config['DATA_DIR'], 'simulate', 'num_trials', 'trials-{n_trials}_a0-{a0}_s0-{s0}_boots-{n_boots}_iter-{max_iter}_data.csv'),
    log:
        op.join(config['DATA_DIR'], 'logs', 'simulate', 'num_trials', 'trials-{n_trials}_a0-{a0}_s0-{s0}_boots-{n_boots}_iter-{max_iter}.log'),
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'simulate', 'num_trials', 'trials-{n_trials}_a0-{a0}_s0-{s0}_boots-{n_boots}_iter-{max_iter}_benchmark.txt'),
    run:
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fig, param, data = fov.simulate.test_num_trials(int(wildcards.n_trials), int(wildcards.n_boots),
                                                                float(wildcards.a0), float(wildcards.s0),
                                                                max_iter=int(wildcards.max_iter))
                fig.savefig(output[0], bbox_inches='tight')
                param.to_csv(output[1], index=False)
                data.to_csv(output[2], index=False)


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
        import foveated_metamers as fov
        import seaborn as sns
        import contextlib
        import re
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                font_scale = {'poster': 1.7}.get(wildcards.context, 1)
                max_ecc = float(re.findall('em-([0-9.]+)_', input[0])[0])
                with sns.plotting_context(wildcards.context, font_scale=font_scale):
                    scaling = {MODELS[0]: config['RGC']['scaling'],
                               MODELS[1]: config['V1']['scaling']}[wildcards.model_name]
                    fig = fov.figures.scaling_comparison_figure(wildcards.model_name,
                        wildcards.image_name, scaling, wildcards.seed, max_ecc=max_ecc)
                    fig.savefig(output[0], bbox_inches='tight')


rule window_size_figure:
    input:
        image = lambda wildcards: [m.replace('metamer.png', 'metamer_gamma-corrected.png') for m in
                                   utils.generate_metamer_paths(**wildcards)],
    output:
        report(op.join(config['DATA_DIR'], 'figures', '{context}', '{model_name}',
                       '{image_name}_scaling-{scaling}_seed-{seed}_gpu-{gpu}_window.png'))
    log:
        op.join(config['DATA_DIR'], 'logs', 'figures', '{context}', '{model_name}',
                '{image_name}_scaling-{scaling}_seed-{seed}_gpu-{gpu}_window.log')
    benchmark:
        op.join(config['DATA_DIR'], 'logs', 'figures', '{context}', '{model_name}',
                '{image_name}_scaling-{scaling}_seed-{seed}_gpu-{gpu}_window_benchmark.txt')
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
    resources:
        mem = get_mem_estimate,
    run:
        import foveated_metamers as fov
        import seaborn as sns
        import contextlib
        import imageio
        import plenoptic as po
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                font_scale = {'poster': 1.7}.get(wildcards.context, 1)
                min_ecc = config['DEFAULT_METAMERS']['min_ecc']
                max_ecc = config['DEFAULT_METAMERS']['max_ecc']
                with sns.plotting_context(wildcards.context, font_scale=font_scale):
                    image = fov.utils.convert_im_to_float(imageio.imread(input.image[0]))
                    # remove the normalizing aspect, since we don't need it here
                    model, _, _, _ = fov.create_metamers.setup_model(wildcards.model_name.replace('_norm', ''),
                                                                     float(wildcards.scaling),
                                                                     image, min_ecc, max_ecc, params.cache_dir)
                    fig = fov.figures.pooling_window_size(model.PoolingWindows, image)
                    fig.savefig(output[0])


rule synthesis_video:
    input:
        METAMER_TEMPLATE_PATH.replace('_metamer.png', '.pt'),
    output:
        [METAMER_TEMPLATE_PATH.replace('metamer.png', f'synthesis-{i}.{f}') for
         i, f in enumerate(['png', 'png', 'png', 'mp4', 'png', 'mp4'])]
    log:
        METAMER_LOG_PATH.replace('.log', '_synthesis_video.log')
    benchmark:
        METAMER_LOG_PATH.replace('.log', '_synthesis_video_benchmark.txt')
    resources:
        mem = get_mem_estimate,
    run:
        import foveated_metamers as fov
        import contextlib
        with open(log[0], 'w', buffering=1) as log_file:
            with contextlib.redirect_stdout(log_file), contextlib.redirect_stderr(log_file):
                fov.figures.synthesis_video(input[0], wildcards.model_name)


rule compute_distances:
    input:
        ref_image = lambda wildcards: utils.get_ref_image_full_path(wildcards.image_name),
        windows = get_windows,
        norm_dict = get_norm_dict,
        synth_images = lambda wildcards: [m.replace('.png', '-16.png') for m in
                                          utils.generate_metamer_paths(wildcards.synth_model_name,
                                                                       image_name=wildcards.image_name)],
    output:
        op.join(config["DATA_DIR"], 'distances', '{model_name}', 'scaling-{scaling}',
                'synth-{synth_model_name}', '{image_name}_e0-{min_ecc}_em-{max_ecc}_distances.csv'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'distances', '{model_name}', 'scaling-{scaling}',
                'synth-{synth_model_name}', '{image_name}_e0-{min_ecc}_em-{max_ecc}_distances.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'distances', '{model_name}', 'scaling-{scaling}',
                'synth-{synth_model_name}', '{image_name}_e0-{min_ecc}_em-{max_ecc}_distances_benchmark.txt')
    params:
        cache_dir = lambda wildcards: op.join(config['DATA_DIR'], 'windows_cache'),
    resources:
        mem = get_mem_estimate,
    run:
        import foveated_metamers as fov
        import plenoptic as po
        import torch
        import pandas as pd
        ref_image = po.load_images(input.ref_image)
        if input.norm_dict:
            norm_dict = torch.load(input.norm_dict)
        else:
            norm_dict = None
        model = fov.create_metamers.setup_model(wildcards.model_name, float(wildcards.scaling),
                                                ref_image, float(wildcards.min_ecc),
                                                float(wildcards.max_ecc), params.cache_dir,
                                                norm_dict)[0]
        synth_scaling = config[wildcards.synth_model_name.split('_')[0]]['scaling']
        df = []
        for sc in synth_scaling:
            df.append(fov.distances.model_distance(model, wildcards.synth_model_name,
                                                   wildcards.image_name, sc))
        df = pd.concat(df).reset_index(drop=True)
        df['distance_model'] = wildcards.model_name
        df['distance_scaling'] = float(wildcards.scaling)
        df.to_csv(output[0], index=False)
