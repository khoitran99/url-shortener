import { IsUrl } from 'class-validator';
import { ShortenRequest } from '@url-shortener/types';

export class ShortenDto implements ShortenRequest {
  @IsUrl({ require_protocol: true }, { message: 'longUrl must be a valid URL with protocol' })
  longUrl!: string;
}
