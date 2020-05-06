module CoderDecoder

using StaticArrays
export codec

MIN_LENGTH_SOURCE_FILE = 1

mutable struct StateMachine
        state_number::Int32
        previous_state::Int32
        state_count::Vector{UInt32}
        general_table::SVector{256,Int32}
        function StateMachine(bit_count = 256)
            b(i)=(i & 1) * 2 + (i & 2) + (i >> 2 & 1) + (i >> 3 & 1) + (i >> 4 & 1) + (i >> 5 & 1) + (i >> 6 & 1) + (i >> 7 & 1) + 3
            state_count = [b(i) << 28 | 6 for i in 0:bit_count-1]
            general_table = UInt32[32768 ÷ (i + i + 3) for i in 0:255]
            previous_state = 0
            new(bit_count, previous_state, state_count, general_table)
        end
end


function getnextbit!(sm::StateMachine, state)::UInt32
    @assert state >= 0 && state < sm.state_number
    sm.previous_state = state
    return sm.state_count[state+1] >> 16
end

function update!(sm::StateMachine, soup_bit, limit=255)::Nothing
    bit_count = sm.state_count[sm.previous_state+1] & 255
    get_next_bit = sm.state_count[sm.previous_state+1] >> 14

    if bit_count < limit
        sm.state_count[sm.previous_state+1] += 1
        delta = (((soup_bit << 18) - get_next_bit) * sm.general_table[bit_count+1]) & 0xffffff00
        sm.state_count[sm.previous_state+1] = unsafe_trunc(UInt32, sm.state_count[sm.previous_state+1] + delta)
    end
    nothing
end

mutable struct Determinant
    previsions_state::Int32
    bit_matrix::StateMachine
    state::MVector{256,Int32}
    Determinant(previsions_state=0, bit_matrix = StateMachine(0x10000)) = new(previsions_state, bit_matrix, fill(Int32(0x66), 256))
end

getnextbit!(det::Determinant)::UInt32 = getnextbit!(det.bit_matrix, det.previsions_state << 8 | det.state[det.previsions_state+1])

function update!(det::Determinant, soup_bit)::Nothing
    update!(det.bit_matrix, soup_bit, 90) # limit = 90
    state_numeration = Ref(det.state, det.previsions_state+1) # Ref to det.state[det.previsions_state+1]
    state_numeration[] += state_numeration[] + soup_bit
    state_numeration[] &= 255
    if (det.previsions_state += det.previsions_state + soup_bit) >= 256
        det.previsions_state = 0
    end
    nothing
end

@enum Mode ENCODE_DATA DECODE_DATA

mutable struct Encoder
    determinant::Determinant
    codec_mode::Mode
    soup::IOStream
    vector_x::UInt32
    vector_y::UInt32
    lambda::UInt32
    function Encoder(io_mode::Mode, file_stream::IOStream)
        lambda = 0
        if io_mode == DECODE_DATA
            for i in 1:4
                if eof(file_stream)
                    byte = UInt8(0)
                else
                    byte = read(file_stream, UInt8)
                end
                lambda = (lambda << 8) + (byte & 0xff)
            end
        end
        vector_x = 0
        vector_y = 0xffffffff
        new(Determinant(), io_mode, file_stream, vector_x, vector_y, lambda)
    end
end # mutable struct Encoder

@inline function encode!(enc::Encoder, soup_bit)::Nothing
    @assert soup_bit in (0, 1)
    soup_mix_byte, _ = soupmixbyte(enc)
    update!(enc, soup_bit, soup_mix_byte)

    while iscondition(enc.vector_x,enc.vector_y) #((enc.vector_x ⊻ enc.vector_y) & 0xff000000) == 0
        write(enc.soup, unsafe_trunc(UInt8, enc.vector_y >> 24))
        enc.vector_x, enc.vector_y = shifts(enc.vector_x, enc.vector_y) # enc.vector_x <<= 8; enc.vector_y = (enc.vector_y << 8) + 255
    end
end # function encode!

@inline function decode!(enc::Encoder)
    soup_mix_byte, _ = soupmixbyte(enc)
    soup_bit = (enc.lambda <= soup_mix_byte) ? 1 : 0
    update!(enc, soup_bit, soup_mix_byte)

    while iscondition(enc.vector_x,enc.vector_y) #((enc.vector_x ⊻  enc.vector_y) & 0xff000000) == 0
        enc.vector_x, enc.vector_y = shifts(enc.vector_x, enc.vector_y) # enc.vector_x <<= 8; enc.vector_y = (enc.vector_y << 8) + 255

        if eof(enc.soup)
            byte = UInt8(0)
        else
            byte = read(enc.soup, UInt8)
        end

        enc.lambda =  UInt32((enc.lambda << 8) + byte)
    end
    return soup_bit
end # function decode!

@inline function update!(enc::Encoder, soup_bit, soup_mix_byte)::Nothing
    @assert  enc.vector_x <= soup_mix_byte < enc.vector_y
    if soup_bit == 1
        enc.vector_y = soup_mix_byte
    else # soup_bit == 0
        enc.vector_x = soup_mix_byte + 1
    end
    update!(enc.determinant, soup_bit)
end

@inline function soupmixbyte(enc::Encoder)::NTuple{2,UInt32}
    get_next_bit = getnextbit!(enc.determinant) # ::UInt32
    @assert get_next_bit <= 0xffff
    return enc.vector_x +
        ((enc.vector_y - enc.vector_x) >> 16) * get_next_bit +
        ((((enc.vector_y - enc.vector_x) & 0xffff) * get_next_bit) >> 16),
        get_next_bit
end

function alignment!(enc::Encoder)::Nothing
    if enc.codec_mode == DECODE_DATA
        return nothing
    end
    while iscondition(enc.vector_x, enc.vector_y) # (((enc.vector_x ⊻ enc.vector_y) & 0xff000000) == 0)
        write(soup, unsafe_trunc(UInt8, enc.vector_y >> 24))
        enc.vector_x, enc.vector_y = shifts(enc.vector_x, enc.vector_y) #enc.vector_x <<= 8; enc.vector_y = (enc.vector_y << 8) + 255
    end
    write(enc.soup, unsafe_trunc(UInt8, enc.vector_y >> 24))
    nothing
end # function alignment!

@inline iscondition(vector_x,vector_y) = (((vector_x ⊻ vector_y) & 0xff000000) == 0)

@inline shifts(vector_x, vector_y) = (vector_x <<= 8, (vector_y << 8) + 255)

function codec(args)
    if length(args) != 3 ||  args[1][1] ∉ ['c','d']
        println("Vector Integer State Prediction Codec (Julia)")
        exit(1)
    end

    file_in, file_out = openfiles(args[2],args[3])

    t_start = time()

    if args[1][1] == 'c'
        if filesize(args[2]) < MIN_LENGTH_SOURCE_FILE
            println("Very small file\n")
            exit(0)
        end
        encode(file_in,file_out)
    else # argv[1][1] == 'd'
        decode(file_in, file_out)
    end
    println("$(args[2]) ($(position(file_in)) bytes) -> $(args[3]) ($(position(file_out)) bytes) in $(time()-t_start) s.\n")
    nothing
end # main function codeс


function encode(file_in::IOStream, file_out::IOStream)
    coder = Encoder(ENCODE_DATA, file_out)
    while !eof(file_in)
        byte = read(file_in, UInt8)
        encode!(coder, 1)
        for i in 7:-1:0
            encode!(coder, (byte >> i) & 1)
        end
    end
    encode!(coder, 0)
    alignment!(coder)
    nothing
end # function encode(::IOStream, ::IOSstream)


function decode(file_in::IOStream, file_out::IOStream)
    coder = Encoder(DECODE_DATA, file_in)
    while decode!(coder) != 0
        byte = 1
        while byte < 256
            byte += byte + decode!(coder)
        end
        write(file_out, unsafe_trunc(UInt8, byte+256))
    end
    encode!(coder, 0)
    # alignment!(coder)
    nothing
end # function decode(::IOStream, ::IOSstream)

function openfiles(file_in, file_out)
    try
        file_in = open(file_in, "r")
    catch exept
        println(exept)
        exit(1)
    end
    if filesize(file_in) == 0
        println("The input file is empty\n")
        exit(0)
    end
    try
        file_out = open(file_out, "w")
    catch exept
        println(exept)
        exit(1)
    end
    return file_in, file_out
end

end
using .CoderDecoder
codec(ARGS)
